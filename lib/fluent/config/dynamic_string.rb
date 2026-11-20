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

require 'fluent/config/error'

module Fluent
  module Config
    # A parameter value of the `:dynamic_string` type.
    #
    # It keeps the configured string as a template, and expands the placeholders
    # in it (e.g. ${tag}, ${key}, %Y%m%d) with the chunk given to #call:
    #
    #   config_param :path, :dynamic_string
    #   # path /path/to/file.${tag}.%Y%m%d.log
    #   @path.call(chunk) #=> "/path/to/file.tag.20221120.log"
    class DynamicString
      attr_reader :string, :owner

      # @param string [String] the configured value, which may contain placeholders
      # @param owner [Fluent::Plugin::Output] a plugin instance which expands the placeholders
      def initialize(string, owner = nil)
        @string = string
        @owner = owner
      end

      # Expands the placeholders with the chunk.
      # @param chunk [Fluent::Plugin::Buffer::Chunk] a chunk which provides tag, time and variables
      def call(chunk)
        unless @owner.respond_to?(:extract_placeholders)
          raise Fluent::ConfigError, "#{@owner.class} does not support #extract_placeholders, which :dynamic_string requires"
        end

        @owner.extract_placeholders(@string, chunk)
      end

      def to_s
        @string
      end

      def inspect
        "#<#{self.class.name} #{@string.inspect}>"
      end
    end
  end
end
