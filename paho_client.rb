require 'thread'
require 'openssl'
require 'socket'

require 'pp'

module PahoRuby

  DEFAULT_SSL_PORT = 8883
  DEFAULT_PORT = 1883
  SELECT_TIMEOUT = 0.5

  class Client

    # MAX size of queue
    MAX_PUBACK = 20
    MAX_PUBREC = 20
    MAX_PUBREL = 20
    MAX_PUBCOMP = 20
    MAX_WRITING = 100
    
    # Connection states values
    MQTT_CS_NEW = 0
    MQTT_CS_CONNECTED = 1
    MQTT_CS_DISCONNECT = 2
    MQTT_CS_CONNECT_ASYNC = 3
    
    # Error values
    MQTT_ERR_AGAIN = -1
    MQTT_ERR_SUCCESS = 0
    MQTT_ERR_NOMEM = 1
    MQTT_ERR_PROTOCOL = 2
    MQTT_ERR_INVAL = 3
    MQTT_ERR_NO_CONN = 4
    MQTT_ERR_CONN_REFUSED = 5
    MQTT_ERR_NOT_FOUND = 6
    MQTT_ERR_CONN_LOST = 7
    MQTT_ERR_TLS = 8
    MQTT_ERR_PAYLOAD_SIZE = 9
    MQTT_ERR_NOT_SUPPORTED = 10
    MQTT_ERR_AUTH = 11
    MQTT_ERR_ACL_DENIED = 12
    MQTT_ERR_UNKNOWN = 13
    MQTT_ERR_ERRNO = 14
    
    # Connection related attributes:
    attr_accessor :host
    attr_accessor :port
    attr_accessor :mqtt_version
    attr_accessor :clean_session
    attr_accessor :client_id
    attr_accessor :username
    attr_accessor :password
    attr_accessor :ssl
    
    # Last will attributes:
    attr_accessor :will_topic
    attr_accessor :will_payload
    attr_accessor :will_qos
    attr_accessor :will_retain

    # Setting attributes:
    attr_accessor :keep_alive
    attr_accessor :ack_timeout

    #Callback attributes
    attr_accessor :on_message
    attr_accessor :on_connack
    attr_accessor :on_suback
    attr_accessor :on_unsuback
    attr_accessor :on_puback
    attr_accessor :on_pubrel
    attr_accessor :on_pubrec
    attr_accessor :on_pubcomp
    attr_accessor :registred_callback
    
    ATTR_DEFAULTS = {
      :host => "",
      :port => nil,
      :mqtt_version => '3.1.1',
      :clean_session => true,
      :client_id => nil,
      :username => nil,
      :password => nil,
      :ssl => false,
      :will_topic => nil,
      :will_payload => nil,
      :will_qos => 0,
      :will_retain => false,
      :keep_alive => 5,
      :ack_timeout => 5,
    }
    
    
    def initialize(*args)
      if args.last.is_a?(Hash)
        attr = args.pop
      else
        attr = {}
      end
      
      ATTR_DEFAULTS.merge(attr).each_pair do |k,v|
        self.send("#{k}=", v)
      end

      if @port.nil?
        @port = @ssl ? PahoRuby::DEFAULT_SSL_PORT : PahoRuby::DEFAULT_PORT
      end
      
      if  @client_id.nil? || @client_id == ""
        @client_id = generate_client_id
      end
      
      @last_ping_req = Time.now
      @last_ping_resp = Time.now
      @last_packet_id = 0
      @socket = nil
      @ssl_context = nil
      @writing_mutex = Mutex.new
      @writing_queue = []
      @connection_state = MQTT_CS_DISCONNECT
      @connection_state_mutex = Mutex.new
      @subscribed_topics = {}
      @subscribed_mutex = Mutex.new
      @waiting_suback = {}
      @suback_mutex = Mutex.new
      @waiting_unsuback = {}
      @unsuback_mutex = Mutex.new
      @main_thread = nil
      
      @puback_mutex = Mutex.new
      @pubrec_mutex = Mutex.new
      @pubrel_mutex = Mutex.new
      @pubcomp_mutex = Mutex.new
      @waiting_puback = []
      @waiting_pubrec = []
      @waiting_pubrel = []
      @waiting_pubcomp = []
      
      @on_conack = nil
      @on_suback = nil
      @on_unsuback = nil
      @on_puback = nil
      @on_pubrel = nil
      @on_pubrec = nil
      @on_pubcomp = nil
      @on_message = nil
      @registred_callback = []
    end

    def generate_client_id(prefix='paho_ruby', lenght=16)
      charset = Array('A'..'Z') + Array('a'..'z') + Array('0'..'9')
      @client_id = prefix << Array.new(lenght) { charset.sample }.join
    end

    def next_packet_id
      @last_packet_id = ( @last_packet_id || 0 ).next
    end
    
    def set_ssl_context(cert_path, key_path, ca_path)
      @ssl ||= true
      @ssl_context = ssl_context
      self.cert = cert_path
      self.key = key_path
      self.root_ca = ca_path
    end

    def config_ssl_socket
      unless @socket.nil?
        @socket.close
      end

      unless @host.nil? || @port < 0
        puts @host
        tcp_socket = TCPSocket.new(@host, @port)
      end

      unless @ssl_context.nil?
        @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, @ssl_context)
        @socket.sync_close = true
        @socket.connect
      end
    end
    
    def ssl_context
      @ssl_context ||= OpenSSL::SSL::SSLContext.new
    end
    
    def cert=(cert_path)
      ssl_context.cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
    end

    def key=(key_path, passphrase=nil)
      ssl_context.key = OpenSSL::PKey::RSA.new(File.read(key_path), passphrase)
    end
    
    def root_ca=(ca_path)
      ssl_context.ca_file = ca_path
      unless @ca_path.nil?
        ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
    end
    
    def config_will(topic, payload="", retain=false, qos=0)
    end
    
    def connect(host, port=1883, keep_alive=6)
      connect_async(host, port, keep_alive)
    end

    def connect_async(host, port=1883, keep_alive=15)
      @host = host
      puts "Try to connect to #{@host}"
      @port = port
      @keep_alive = keep_alive

      @connection_state_mutex.synchronize {
        @connection_state = MQTT_CS_CONNECT_ASYNC
      }
      setup_connection
    end

    def setup_connection
      @main_thread.kill if @main_thread and @main_thread.alive?
      @main_thread = nil
      
      if @host.nil? || @host == ""
        raise "Connection Failed, host cannot be nil or empty"
      end
      
      if @port <= 0
        raise "Connection Failed port cannot be 0 >="
      end

      unless @ssl_context.nil?
        unless @socket.nil?
          @socket.close
        end
      end
      
      @last_ping_req = Time.now
      @last_ping_resp = Time.now

      config_ssl_socket
      send_connect

      # Waiting a Connack packet for 2 second from the remote 
      connect_timeout = Time.now + 2
      while (Time.now <= connect_timeout) && (@connection_state != MQTT_CS_CONNECTED) do
        receive_packet
      end
      
      if @connection_state != MQTT_CS_CONNECTED
        raise "Didn't receive Connack answer from server #{@host}"
      end

      next_packet_id

      @main_thread = Thread.new(Thread.current) do |parent|
        Thread.current[:parent] = parent
        while @connection_state == MQTT_CS_CONNECTED do
          mqtt_loop
        end
      end
    end
    
    def loop_write(max_packet=MAX_WRITING)
      @writing_mutex.synchronize {
        cnt = 0
        while !@writing_queue.empty? or cnt >= max_packet do
          send_packet(@writing_queue.shift)
          cnt += 1
        end
      }
    end

    def loop_read(max_packet=5)
      receive_packet
    end
    
    def mqtt_loop
      loop_read
      loop_write
      loop_misc
    end

    def loop_misc
      check_keep_alive
      check_ack_alive(@waiting_puback, @puback_mutex, MAX_PUBACK)
      check_ack_alive(@waiting_pubrec, @pubrec_mutex, MAX_PUBREC)
      check_ack_alive(@waiting_pubrel, @pubrel_mutex, MAX_PUBREL)
      check_ack_alive(@waiting_pubcomp, @pubcomp_mutex, MAX_PUBCOMP)
      check_ack_alive(@waiting_suback, @suback_mutex, @waiting_suback.length)
      check_ack_alive(@waiting_unsuback, @unsuback_mutex, @waiting_unsuback.length)
    end
    
    def check_keep_alive
      now = Time.now
      if @keep_alive > 0 && @connection_state == MQTT_CS_CONNECTED 
        timeout_req = @last_ping_req + (@keep_alive * 0.7) 
        if timeout_req <= now
          send_pingreq
          @last_ping_req = now
        end

        timeout_resp = @last_ping_resp + (@keep_alive * 1.4 ).ceil
        if timeout_resp <= now
          puts "Didn't get answer from server for long times, disconnecting."
          disconnect
        end
      end
    end

    def check_ack_alive(queue, mutex, max_packet)
      mutex.synchronize {
        now = Time.now
        cnt = 0
        pp queue unless queue.empty?
        queue.each do |pck|
          pp pck
          if now >= mess.timestamp + @ack_timeout
            pck.packet.dup ||= true unless pck.packet.class == PahoRuby::Packet::Subscribe || pck.packet.class == PahoRuby::Packet::Unsubscribe
            unless cnt > max_packet
              append_to_writing(pck.packet) 
              pck.timestamp = now
              cnt += 1
            end
          end
        end
      }
    end

    def append_to_writing(packet)
      @writing_mutex.synchronize {
        @writing_queue.push(packet)
      }
    end

    def config_all_message_queue
      config_message_queue(@waiting_puback, @puback_mutex, MAX_PUBACK)
      config_message_queue(@waiting_pubrec, @pubrec_mutex, MAX_PUBREC)
      config_message_queue(@waiting_pubrel, @pubrel_mutex, MAX_PUBREL)
      config_message_queue(@waiting_pubcomp, @pubcomp_mutex, MAX_PUBCOMP)
    end
    
    def config_message_queue(queue, mutex, max_packet)
      mutex.synchronize {
        cnt = 0 
        queue.each do |pck|
          pck.packet.dup ||= true
          if cnt <= max_packet
            append_to_writing(pck)
            cnt += 1
          end
        end
      }
    end
    
    def disconnect
      puts "Disconnecting"
      @connection_state_mutex.synchronize {
        @connection_state = MQTT_CS_DISCONNECT
      }
      
      unless @socket.nil?
        send_disconnect
        @socket.close
        @socket = nil
      end

      @writing_mutex.synchronize {
        @writing_queue = []
      }

      @puback_mutex.synchronize {
        @waiting_puback = []
      }

      @pubrec_mutex.synchronize {
        @waiting_pubrec = []
      }

      @pubrel_mutex.synchronize {
        @waiting_pubrel = []
      }

      @pubcomp_mutex.synchronize {
        @waiting_pubcomp = []
      }

      @main_thread.kill if @main_thread and @main_thread.alive?
      @main_thread = nil
    end
    
    def publish(topic="", payload="", retain=false, qos=0)
      if topic == "" || !topic.is_a?(String)
        raise "Publish error, topic in empty or invalid"
      end
        send_publish(topic, payload, retain, qos)
    end

    def subscribe(*topics)
      unless topics.length == 0
        send_subscribe(topics)
      else
        raise "Protocol Violation, subscribe topics list must not be empty."
      end
    end

    def unsubscribe(*topics)
      unless topics.length == 0
        send_unsubscribe(topics)
      else
        raise "Protocol Violation, unsubscribe topics list must not be empty."
      end
    end
    
    def receive_packet
      begin
        result = IO.select([@socket], [], [], SELECT_TIMEOUT)
        unless result.nil?
          packet = PahoRuby::Packet.read(@socket)
          handle_packet packet
          @last_ping_resp = Time.now
        end
      rescue Exception => exp
        unless @socket.nil?
          @socket.close
          @socket = nil
        end
        raise(exp)
      end
    end
    
    def handle_packet(packet)
      if packet.class == PahoRuby::Packet::Connack
        handle_connack(packet)
      elsif packet.class == PahoRuby::Packet::Suback
        handle_suback(packet)
      elsif packet.class == PahoRuby::Packet::Unsuback
        handle_unsuback(packet)
      elsif packet.class == PahoRuby::Packet::Publish
        handle_publish(packet)
      elsif packet.class == PahoRuby::Packet::Puback
        handle_puback(packet)
      elsif packet.class == PahoRuby::Packet::Pubrec
        handle_pubrec(packet)
      elsif packet.class == PahoRuby::Packet::Pubrel
        handle_pubrel(packet)
      elsif packet.class == PahoRuby::Packet::Pubcomp
        handle_pubcomp(packet)
      elsif packet.class ==PahoRuby::Packet::Pingresp
        handle_pingresp
      else
        raise ProtocolExecption.new("Unknow packet received")
      end
    end

    def handle_connack(packet)
      puts "Connack packet received"
      if packet.return_code == 0x00        
        puts "Connection accepted, ready to process"
        if @clean_session && !packet.session_present
          puts "New SSL session created"
        elsif !@clean_session && !packet.session_present
          puts "Could not find SSL session on server side, starting a new one."
          
        elsif !@clean_session && packet.session_present
          puts "Retrieving previous SSL session on server side."
        end
        
        @connection_state_mutex.synchronize{
          @connection_state = MQTT_CS_CONNECTED
        }
        
      else
        handle_connack_error(packet.return_code)
      end
      
      # To complete with publish
      config_all_message_queue

      @writing_mutex.synchronize {
        @writing_queue.each do |m|
          m.timestamp = Time.now
          send_packet(m)
        end
      }
    end

    def handle_pingresp
      puts "Connection to Server is still alive"
      @last_ping_resp = Time.now
    end
    
    def handle_suback(packet) 
      puts "Got suback"
      adjust_qos = []
      max_qos = packet.return_codes
      @suback_mutex.synchronize {
        adjust_qos = @waiting_suback.delete_if { |pck| pck.id == packet.id }
      }

      pp adjust_qos
      adjust_qos.each do |topic, qos|
        ["0", "1", "2"].include?(max_qos[0]) ? adjust_qos.delete(topic) : adjust_qos[topic] = max_qos.shift
      end
      
      @subscribed_mutex.synchronize {
        @subscribed_topics.concat(adjust_qos)
      }
    end

    def handle_unsuback(packet)
      to_unsub = []
      @unsuback_mutex.synchronize {
        to_unsub = @waiting_unsuback.delete_if { |pck| pck.id == packet.id }
      }

      @subscribed_mutex.synchronize {
        to_unsub.topics.each do |filter|
          @subscribed_topics.delete_if { |topic| match_filter(topic, filter) }
        end
      }
    end
    
    def handle_publish(packet)
      puts "Received publish"
      puts "Topic : #{packet.topic}\nPayload: #{packet.payload}\nQos: #{packet.qos}"
    end
    
    def handle_puback(packet)
      puts "Received Puback"
    end

    def handle_pubrec(packet)
      puts "Received Pubrec"
      @pubrec_mutex.synchronize {
        @waiting_pubrec.delete_if { |pck| pck.id == packet.id}
      }
      send_pubrel(packet.id)
    end

    def handle_pubrel(packet)
      puts "Received Pubrel"
    end

    def handle_pubcomp(packet)
      puts "Received Pubcomp"
      @pubcomp_mutex.synchronize {
        @waiting_pubcomp.delete_if { |pck| pck.id == packet.id }
      }
    end
    
    ### MOVE TO ERROR HANDLER CLASS
    def handle_connack_error(return_code)
      case return_code
      when 0x01
        puts "Unable to connect with this version #{@mqtt_version}"
        if @mqtt_version == "3.1.1"
          @mqtt_version = "3.1"
          connect(@host)
        end
      when 0x02
        
      when 0x03

      when 0x04

      when 0x05

      end
    end
    
    def send_packet(packet)
      @socket.write(packet.to_s)
      @last_ping_req = Time.now
    end
    
    def send_connect
      packet = PahoRuby::Packet::Connect.new(
        :version => @mqtt_version,
        :clean_session => @clean_session,
        :keep_alive => @keep_alive,
        :client_id => @client_id,
        :username => @username,
        :password => @password,
        :will_topic => @will_topic,
        :will_payload => @will_payload,
        :will_qos => @will_qos,
        :will_retain => @will_retain
      )
      send_packet(packet)
    end

    def send_disconnect
      packet = PahoRuby::Packet::Disconnect.new
      send_packet(packet)
    end

    def send_pingreq
      packet = PahoRuby::Packet::Pingreq.new
      send_packet(packet)
    end

    
    def send_subscribe(topics)
      unless topics.length == 0
        new_id = next_packet_id
        packet = PahoRuby::Packet::Subscribe.new(
          :id => new_id,
          :topics => topics
        )
        
        @suback_mutex.synchronize {
          @waiting_suback.push({ :id => new_id, :packet => packet, :timestamp => Time.now })
        }
        # Throw a time out
        append_to_writing(packet)
      else
        raise "Protocol Violation, subscribe topics list must not be empty."
      end        
    end

    def send_unsubscribe(topics)
      unless topics.length == 0
        new_id = next_packet_id
        packet = PahoRuby::Packet::Unsubscribe.new(
          :id => new_id,
          :topics => topics
        )

        @unsuback_mutex.synchronize {
          @waiting_unsuback.push({:id => new_id, :packet => packet, :timestamp => Time.now})
        }
        append_to_writing(packet)
      else
        raise "Protocol Violation, subscribe topics list must not be empty."
      end
    end

    def send_publish(topic, payload, retain, qos)
      new_id = next_packet_id
      
      packet = PahoRuby::Packet::Publish.new(
        :id => new_id,
        :topic => topic,
        :payload => payload,
        :retain => retain,
        :qos => qos
      )
      append_to_writing(packet)
      
      case qos
      when 1
        @puback_mutex.synchronize{
          @waiting_puback.push({:id => new_id, :packet => packet, :timestamp => Time.now})
        }
      when 2
        @pubrec_mutex.synchronize{
          @waiting_pubrec.push({:id => new_id, :packet => packet, :timestamp => Time.now})
        }
      end
    end
    
    def send_pubrel(packet_id)
      packet = PahoRuby::Packet::Pubrel.new(
        :id => packet_id
      )
      append_to_writing(packet)
      
      @pubcomp_mutex.synchronize{
        @waiting_pubcomp.push({:id => packet_id, :packet => packet, :timestamp => Time.now})
      }
    end
    
    private

    def match_filter(topics, filters)
      if topics.is_a?(String) && filters.is_a?(String)
        topic = topics.split('/')
        filter = filters.split('/')
      else
        raise "Invalid parameter type #{topics.class} and #{filters.class}"
      end
      
      rc = false
      index = 0
      
      while index < [topic.length, filter.length].max do
        if topic[index].nil? || filter[index].nil?
          break
        elsif filter[index] == '#' && index == (filter.length - 1) 
          rc = true
          break
        elsif filter[index] == topic[index] || filter[index] == '+'
          index = index + 1
        else
          break
        end
      end
      rc ||= (index == [topic.length, filter.length].max)
    end
  end
end