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

require 'async'
require 'async/http'
require 'async/http/endpoint'
require 'uri'

require 'fluent/log/console_adapter'

module Fluent
  module RPC
    # RPC server implementation based on async-http.
    #
    # This is used by the supervisor's `rpc_endpoint` and is the replacement
    # for the previous WEBrick based implementation. WEBrick is no longer
    # recommended for production use, so the RPC server has been migrated to
    # the same async-http stack that the `http_server` plugin helper uses.
    class Server
      def initialize(endpoint, log)
        m = endpoint.match(/^\[?(?<host>[0-9a-zA-Z:\-\.]+)\]?:(?<port>[0-9]+)$/)
        raise Fluent::ConfigError, "Invalid rpc_endpoint: #{endpoint}" unless m
        @bind = m[:host]
        @port = m[:port]
        @log = log

        # Normalize the address for the async-http endpoint.
        # Brackets are only for URI formatting, not for socket binding.
        addr = if @bind.start_with?('[') && @bind.end_with?(']')
                 @bind[1..-2]
               else
                 @bind
               end
        ip_literal = addr.include?(":") ? "[#{addr}]" : addr
        @uri = URI("http://#{ip_literal}:#{@port}").to_s
        @router = {}
        @server_task_queue = ::Thread::Queue.new
        Console.logger = Fluent::Log::ConsoleAdapter.wrap(@log)

        @server = Async::HTTP::Server.new(App.new(self, @log), Async::HTTP::Endpoint.parse(@uri))
      end

      # Kept for compatibility with the old WEBrick based API, where a servlet
      # class with a `#service` method could be mounted. The current RPC
      # handlers are all mounted with #mount_proc, so this raises a clear error
      # if a servlet class is mounted instead.
      def mount(path, servlet, *args)
        raise ArgumentError, "RPC server no longer supports mounting servlet classes"
      end

      def mount_proc(path, &block)
        @router[path] = block
        @log.debug "register #{path} RPC handler"
      end

      def start
        @log.debug "listening RPC http server on http://#{@bind}:#{@port}/"
        @thread = Thread.new {
          Async do |task|
            Console.logger = Fluent::Log::ConsoleAdapter.wrap(@log)
            begin
              @server.endpoint.accept(&@server.method(:accept))
              @server_task_queue.pop
            rescue => e
              @log.error "failed to run RPC server", error: e.to_s
            ensure
              task.children&.each(&:stop)
            end
          end
        }
      end

      def shutdown
        if @server
          @server_task_queue.push(:stop)
          @server = nil
        end
        if @thread
          @thread.join
          @thread = nil
        end
      end

      # App is a rack-like application passed to Async::HTTP::Server.
      class App
        def initialize(server, logger)
          @server = server
          @logger = logger
        end

        def call(request)
          handler = @server.instance_variable_get(:@router)[request.path]
          if handler
            status, headers, body = handler.call(request, nil)
            [status, headers, body]
          else
            [404, { 'Content-Type' => 'text/plain' }, "404 Not Found\n"]
          end
        rescue => e
          @logger.error "failed to handle RPC request", error: e.to_s
          @logger.error e.backtrace.join("\n") if e.backtrace
          [500, { 'Content-Type' => 'text/plain' }, "500 Internal Server Error\n"]
        end
      end
    end
  end
end