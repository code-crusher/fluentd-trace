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

require 'stringio'
require 'zlib'
require 'zstd-ruby'
require 'fluent/error'

module Fluent
  module Plugin
    module Extractor
      class SizeLimitError < UnrecoverableError; end

      BYTES_TO_READ = 64 * 1024
      INFLATE_BYTES_TO_READ = 1024
      # The number of compressed bytes to read at once when decompressing zstd data.
      ZSTD_BYTES_TO_READ = 64 * 1024

      def self.decompress_gzip(compressed_data, limit:)
        io = StringIO.new(compressed_data)
        out = ''
        loop do
          reader = Zlib::GzipReader.new(io)
          while (chunk = reader.read(BYTES_TO_READ))
            out << chunk
            if out.bytesize > limit
              raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
            end
          end

          unused = reader.unused
          reader.finish
          unless unused.nil?
            adjust = unused.length
            io.pos -= adjust
          end
          break if io.eof?
        end
        out
      end

      def self.decompress_zstd(compressed_data, limit:)
        # Do not use Zstd::StreamReader: the streaming feature of zstd-ruby is
        # experimental and had some problems (https://github.com/fluent/fluentd/issues/5111).
        # Zstd::StreamingDecompress#decompress handles concatenated frames correctly
        # and it does not buffer the decompressed data internally.
        decompressor = Zstd::StreamingDecompress.new
        out = +''.force_encoding(Encoding::ASCII_8BIT)
        offset = 0
        while offset < compressed_data.bytesize
          chunk = decompressor.decompress(compressed_data.byteslice(offset, ZSTD_BYTES_TO_READ))
          offset += ZSTD_BYTES_TO_READ
          next if chunk.empty?
          out << chunk
          if out.bytesize > limit
            raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
          end
        end
        out
      end

      def self.decompress_deflate(compressed_data, limit:)
        io = StringIO.new(compressed_data)
        out = ''
        begin
          zstream = Zlib::Inflate.new
          while (chunk = io.read(INFLATE_BYTES_TO_READ))
            out << zstream.inflate(chunk)
            if out.bytesize > limit
              raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
            end
          end
          out << zstream.finish
          if out.bytesize > limit
            raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
          end
        ensure
          zstream&.close
        end
        out
      end

      def self.io_decompress_gzip(input, output, limit:)
        size = 0
        loop do
          reader = Zlib::GzipReader.new(input)
          while (chunk = reader.read(BYTES_TO_READ))
            size += chunk.bytesize
            if size > limit
              raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
            end
            output.write(chunk)
          end
          unused = reader.unused
          reader.finish
          unless unused.nil?
            adjust = unused.length
            input.pos -= adjust
          end
          break if input.eof?
        end
        output
      end

      def self.io_decompress_zstd(input, output, limit:)
        decompressor = Zstd::StreamingDecompress.new
        size = 0
        loop do
          compressed_chunk = input.read(ZSTD_BYTES_TO_READ)
          break if compressed_chunk.nil?
          chunk = decompressor.decompress(compressed_chunk)
          next if chunk.empty?
          size += chunk.bytesize
          if size > limit
            raise SizeLimitError, "Decompressed data exceeds limit of #{limit} bytes"
          end
          output.write(chunk)
        end
        output
      end
    end
  end
end
