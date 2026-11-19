#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'json'

module Fluent
  # Returns an incremental parser for streams of concatenated JSON documents,
  # with the same interface as JSON::ResumableParser:
  #
  #   parser << chunk            # feed the next bytes of the stream
  #   parser.parse               # -> true once a complete document is ready
  #   parser.value               # -> the parsed document
  #   parser.empty?              # -> true when the stream ended cleanly
  #
  # JSON::ResumableParser (json gem >= 2.20) is a native extension and is not
  # provided on every interpreter Fluentd supports (e.g. JRuby), so fall back
  # to a pure Ruby parser there.
  module JSONResumableParserFactory
    def self.parser(options = Fluent::DEFAULT_JSON_PARSE_OPTIONS)
      if defined?(JSON::ResumableParser)
        JSON::ResumableParser.new(**options)
      else
        PureResumableParser.new(options)
      end
    end

    # A pure Ruby substitute for JSON::ResumableParser.
    #
    # Documents are framed by scanning the buffer for the end of the next
    # complete value at the top level, then parsed one by one with JSON.parse.
    #
    # Unlike the native parser, framing cannot tell a complete literal such as
    # `"tru"` from one that continues in the next chunk, but any such slice
    # fails JSON.parse and the completed text parses once the rest of the
    # stream arrives, so records are neither lost nor duplicated.
    class PureResumableParser
      WS = [0x20, 0x09, 0x0A, 0x0D].freeze              # space, tab, LF, CR
      # Bytes that end a number or a junk token: whitespace and `,`, `:`, `"`,
      # `{`, `[`, `}`, `]`, `/`
      TOKEN_END = (WS + [0x2C, 0x3A, 0x22, 0x7B, 0x5B, 0x7D, 0x5D, 0x2F]).freeze
      LITERALS = ['true'.b.freeze, 'false'.b.freeze, 'null'.b.freeze].freeze
      NUMBER = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/.freeze

      def initialize(options = nil)
        @options = options || {}
        @buffer = +''.b
        @value = nil
      end

      def <<(chunk)
        @buffer << chunk
        self
      end

      def parse
        length = scan_document_end(@buffer)
        return false unless length
        document = @buffer.byteslice(0, length)
        @value = JSON.parse(document, **@options)
        @buffer.slice!(0, length)
        true
      end

      def value
        value = @value
        @value = nil
        value
      end

      def empty?
        # The native parser eats trailing whitespace and closed block comments
        # after the last document, so a rest made only of them means a cleanly
        # ended stream. An unterminated comment or a line comment keeps the
        # stream open.
        @value.nil? && strip_comments(@buffer).strip.empty?
      end

      private

      # Removes closed block comments; an unterminated one stays in place.
      def strip_comments(buffer)
        buffer.gsub(%r{/\*.*?\*/}m, '')
      end

      # Returns the length of the next complete top level document in `buffer`,
      # or nil while the document is still incomplete.
      #
      # A top level document ends when a closing bracket balances an open one,
      # a string at its closing quote, or a scalar at the first byte that
      # cannot belong to it (true/false/null also frame at the end of the
      # buffer). Comments are skipped like whitespace, but only when they can
      # be recognized, so that a stray `/` still fails JSON.parse like the
      # native parser does. Bytes that start no document (a stray `,` or a
      # letter breaking a number) frame a token of their own; JSON.parse
      # rejects it just like the native parser rejects the same input.
      def scan_document_end(buffer)
        i = 0
        bytesize = buffer.bytesize
        depth = 0
        in_string = false
        escaped = false
        started = false

        while i < bytesize
          byte = buffer.getbyte(i)
          if in_string
            if escaped
              escaped = false
            elsif byte == 0x5C # backslash: the next byte is escaped
              escaped = true
            elsif byte == 0x22 # double quote: end of string
              return i + 1 if depth == 0 # a string document ends here
              in_string = false
            end
            i += 1
            next
          end

          case byte
          when *WS
            if depth == 0 && started
              return i
            end
            i += 1
          when 0x2F # /
            case buffer.getbyte(i + 1)
            when 0x2F # // line comment: ends at the next newline
              j = buffer.index("\n", i + 2)
              return nil unless j
              i = j + 1
            when 0x2A # /* block comment: ends at the next */
              j = buffer.index('*/', i + 2)
              return nil unless j
              i = j + 2
            else
              # a stray slash starts no document; JSON.parse rejects it
              if depth == 0
                started = true
                return bytesize
              end
              i += 1
            end
          when 0x22 # "
            started = true
            in_string = true
            i += 1
          when 0x7B, 0x5B # { [
            started = true
            depth += 1
            i += 1
          when 0x7D, 0x5D # } ]
            depth -= 1
            i += 1
            if depth <= 0
              # A closing bracket without a matching open one closes the current
              # document; JSON.parse then rejects the malformed slice.
              return started || depth < 0 ? i : nil
            end
          when 0x2C, 0x3A # , :
            if depth > 0
              i += 1
              next
            end
            # a separator outside any document starts no document;
            # JSON.parse rejects the token framed around it
            started = true
            return i + 1
          else
            if depth > 0
              i += 1
              next
            end
            # a scalar at the top level: a literal, a number, or junk
            started = true
            if (literal = LITERALS.find { |l| buffer.byteslice(i, l.bytesize) == l })
              return i + literal.bytesize
            end
            j = i
            j += 1 while j < bytesize && !TOKEN_END.include?(buffer.getbyte(j))
            token = buffer.byteslice(i, j - i)
            if j == bytesize # the scalar may continue in the next chunk
              if NUMBER.match?(token) || token.match?(/\A[\d.eE+-]+\z/) || LITERALS.any? { |l| l.start_with?(token) && token != l }
                return nil
              end
              return j # a junk token: frame it so that JSON.parse rejects it
            end
            if NUMBER.match?(token) || LITERALS.any? { |l| l.start_with?(token) && token != l }
              # a complete number, or a literal still waiting for its letters:
              # frame the number; a partial literal may grow in the next chunk
              return j
            end
            if token.match?(/\A[\d.eE+-]+\z/)
              # not a valid number, but only number characters: the native
              # parser rejects it as an invalid number at this point
              return j
            end
            # a partial literal interrupted by a delimiter swallows the rest
            # of the token so that JSON.parse rejects it
            j += 1 while j < bytesize && !WS.include?(buffer.getbyte(j))
            return j
          end
        end
        nil
      end
    end
  end
end
