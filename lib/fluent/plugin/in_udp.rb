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

require 'fluent/plugin/input'
require 'ipaddr'
require 'socket'

module Fluent::Plugin
  class UdpInput < Input
    Fluent::Plugin.register_input('udp', self)

    helpers :server, :parser, :extract, :compat_parameters

    desc 'Tag of output events.'
    config_param :tag, :string
    desc 'The port to listen to.'
    config_param :port, :integer, default: 5160
    desc 'The bind address to listen to.'
    config_param :bind, :string, default: '0.0.0.0'

    desc "The field name of the client's hostname."
    config_param :source_host_key, :string, default: nil, deprecated: "use source_hostname_key instead."
    desc "The field name of the client's hostname."
    config_param :source_hostname_key, :string, default: nil
    desc "The field name of the client's address."
    config_param :source_address_key, :string, default: nil

    desc "Deprecated parameter. Use message_length_limit instead"
    config_param :body_size_limit, :size, default: nil, deprecated: "use message_length_limit instead."
    desc "The max bytes of message"
    config_param :message_length_limit, :size, default: 4096
    desc "Remove newline from the end of incoming payload"
    config_param :remove_newline, :bool, default: true
    desc "The max size of socket receive buffer. SO_RCVBUF"
    config_param :receive_buffer_size, :size, default: nil, deprecated: "use receive_buffer_size in transport section instead."

    desc "The multicast group address to join. If set, the socket joins the multicast group of the specified address."
    config_param :group, :string, default: nil

    config_param :blocking_timeout, :time, default: 0.5

    # overwrite server plugin to change default to :udp and remove tcp/tls protocol from list
    config_section :transport, required: false, multi: false, init: true, param_name: :transport_config do
      config_argument :protocol, :enum, list: [:udp], default: :udp
    end

    def configure(conf)
      compat_parameters_convert(conf, :parser)
      parser_config = conf.elements('parse').first
      unless parser_config
        raise Fluent::ConfigError, "<parse> section is required."
      end
      super
      @_event_loop_blocking_timeout = @blocking_timeout
      @source_hostname_key ||= @source_host_key if @source_host_key
      @message_length_limit = @body_size_limit if @body_size_limit

      @parser = parser_create(conf: parser_config)

      if @group
        begin
          group_ip = IPAddr.new(@group)
        rescue IPAddr::InvalidAddressError
          raise Fluent::ConfigError, "invalid multicast group address: #{@group}"
        end
        unless multicast_address?(group_ip)
          raise Fluent::ConfigError, "invalid multicast group address: #{@group}"
        end
      end
    end

    def multi_workers_ready?
      # Multicast membership is a property of a single socket. Multiple
      # workers each creating their own socket and joining the same group is
      # not supported, so the plugin cannot run with multiple workers.
      @group.nil?
    end

    def zero_downtime_restart_ready?
      true
    end

    def start
      super

      log.info "listening udp socket", bind: @bind, port: @port
      server = server_create(:in_udp_server, @port, proto: :udp, bind: @bind, resolve_name: !!@source_hostname_key, max_bytes: @message_length_limit, receive_buffer_size: @receive_buffer_size) do |data, sock|
        data.chomp! if @remove_newline
        begin
          @parser.parse(data) do |time, record|
            unless time && record
              log.on_warn { log.warn "pattern not matched", data: data }
              next
            end

            tag = extract_tag_from_record(record)
            tag ||= @tag
            time ||= extract_time_from_record(record) || Fluent::EventTime.now
            record[@source_address_key] = sock.remote_addr if @source_address_key
            record[@source_hostname_key] = sock.remote_host if @source_hostname_key
            router.emit(tag, time, record)
          end
        end
      end

      join_multicast_group(server) if @group
    end

    private

    def multicast_address?(addr)
      if addr.ipv4?
        (addr.to_i & 0xF0000000) == 0xE0000000
      else
        (addr.to_i >> 120) == 0xFF
      end
    end

    def join_multicast_group(server)
      # The server helper wraps the underlying UDPSocket in an event loop
      # watcher. Get the raw socket to set the multicast membership option.
      sock = server.instance_variable_get(:@sock)
      group = IPAddr.new(@group)
      if group.ipv4?
        # struct ip_mreq { struct in_addr imr_multiaddr; struct in_addr imr_interface; }
        membership = group.hton + IPAddr.new(@bind).hton
        sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, membership)
      else
        # struct ipv6_mreq { struct in6_addr ipv6mr_multiaddr; unsigned int ipv6mr_interface; }
        ifindex = multicast_interface_index(@bind)
        membership = group.hton + [ifindex].pack('I')
        sock.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_JOIN_GROUP, membership)
      end
    end

    def multicast_interface_index(bind)
      # Find the network interface that owns the bind address. For an
      # unspecified address (::), fall back to the first non-loopback
      # IPv6 interface, and finally to the loopback interface.
      if bind && bind != "::"
        bind_addr = IPAddr.new(bind)
        Socket.getifaddrs.each do |ifa|
          next unless ifa.addr && ifa.addr.ipv6?
          return ifa.ifindex if ifa.addr.ip_address == bind_addr.to_s
        end
      end
      Socket.getifaddrs.each do |ifa|
        next unless ifa.addr && ifa.addr.ipv6?
        next if ifa.name == "lo"
        return ifa.ifindex
      end
      1
    end
  end
end
