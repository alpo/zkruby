module ZooKeeper
    
    class WatchEvent
        include Enumeration
        enum :none,-1,[]
        enum :node_created, 1, [ :data, :exists ]
        enum :node_deleted, 2, [ :data, :children ]
        enum :node_data_changed, 3, [ :data, :exists ]
        enum :node_children_changed, 4, [ :children ]
        
        attr_reader :watch_types
        def initialize(watch_types)
            @watch_types = watch_types
        end
    end

  
     # Represents an session that may span connections
     class Session

        DEFAULT_TIMEOUT = 4
        DEFAULT_CONNECT_DELAY = 0.2
        include ZooKeeper::Logger

        attr_reader :ping_interval
        attr_reader :conn
        attr_reader :binding
        attr_reader :timeout

        def initialize(binding,addresses,options=nil)
            
            @binding = binding

            @addresses = parse_addresses(addresses)
            parse_options(options)
            
            # These are the server states
            # :disconnected, :connected, :auth_failed, :expired
            @keeper_state = nil

            # Client state is
            # :ready, :closing, :closed
            @client_state = :ready

            @xid=0
            @pending_queue = []

            # Create the watch list
            @watches = [ :children, :data, :exists ].inject({}) do |ws,wtype| 
                ws[wtype] = Hash.new() { |h,k| h[k] = Set.new() }
                ws
            end

        end
     
        # Connection API - testing whether to send a ping
        def connected?()
            @keeper_state == :connected
        end

        # Connection API - Injects a new connection that is ready to receive records
        # @param conn that responds to #send_records(record...) and #disconnect()
        def prime_connection(conn)
            @conn = conn
            
            req = Proto::ConnectRequest.new( :timeout => timeout )
            req.last_zxid_seen = @last_zxid_seen if @last_zxid_seen
            req.session_id =  @session_id if @session_id
            req.passwd = @session_passwd if @session_passwd

            @conn.send_records(req)

            #TODO Send auth data

            #TODO Reset watches (SetWatches)
            # Watches are dropped on disconnect, we reset them here
            # dropping connections can be a good way of cleaning up on the server side
            # If watch reset is disabled the watches will be notified of connection loss
            # otherwise if set watches fails, all watches will be notified of connection loss
            # This way a watch is only ever triggered exactly once
            # we only keep data watches and child watches, even though server handles exists
            # watches. We might need exists watches as they are handled on the server end
            # although I can't quite understand the difference
        end

        # Connection API - called when data is available, reads and processes one packet/event
        # @param io <IO> 
        def receive_records(io)
           case @keeper_state
           when :disconnected
              complete_connection(io)
           when :connected
              process_reply(io)
           else
              log.warn { "Receive packet for closed session #{@keeper_state}" }
           end
        end

        # Connection API - called when no data has been received for #ping_interval
        def ping()
            if @keeper_state == :connected
                log.debug { "Ping send" }
                hdr = Proto::RequestHeader.new(:xid => -2, :type => 11)
                @conn.send_records(hdr)
            end
        end

        # Connection API - called when the connection has dropped from either end
        def disconnected()
           @conn = nil
           log.info { "Disconnected id=#{@session_id}, keeper=:#{@keeper_state}, client=:#{@client_state}" }
          
           # We keep trying to reconnect until the session expiration time is reached
           @disconnect_time = Time.now if @keeper_state == :connected
           time_since_first_disconnect = (Time.now - @disconnect_time) 

           if @client_state == :closed || time_since_first_disconnect > timeout
                session_expired()
           else
                # if we are connected then everything in the pending queue has been sent so
                # we must clear
                # if not, then we'll keep them and hope the next reconnect works
                clear_pending_queue(:connection_lost) if @keeper_state == :connected
                @keeper_state = :disconnected
                reconnect()
           end
        end

        # Start the session - called by the ProtocolBinding
        def start()
            raise ProtocolError, "Already started!" unless @keeper_state.nil?
            @keeper_state = :disconnected
            @disconnect_time = Time.now
            log.debug ("Starting new zookeeper client session")
            reconnect()
        end
       
        def queue_request(request,op,opcode,response=nil,watch_type=nil,watcher=nil,ptype=Packet,&callback)
            raise ZooKeeperError.new(:session_expired) unless @client_state == :ready

            watch_type, watcher = resolve_watcher(watch_type,watcher)

            xid = next_xid

            packet = ptype.new(xid,op,opcode,request,response,watch_type,watcher, callback)
            
            queue_packet(packet)
            
            QueuedOp.new(packet)
        end

        def close(&blk)
            #TODO possibly this should not be an exception
            #TODO although if not an exception, perhaps should yield the block
            raise ZooKeeperError.new(:session_expired) unless @client_state == :ready

            # we keep the requested block in a close packet
            @close_packet = ClosePacket.new(next_xid(),:close,-11,nil,nil,nil,nil,blk)
            @client_state = :closing

            # If there are other requests in flight, then we wait for them to finish
            # before sending the close packet since it immediately causes the socket
            # to close.
            queue_close_packet_if_necessary()
            QueuedOp.new(@close_packet)
        end
        private

        def parse_addresses(addresses)
            case addresses
            when String
                parse_addresses(addresses.split(","))
            when Array
                result = addresses.collect() { |addr| parse_address(addr) }
                #Randomise the connection order
                result.shuffle!
            else
                raise ArgumentError "Not able to parse addresses from #{addresses}"
            end
        end

        def parse_address(address)
            case address
            when String
                host,port = address.split(":")
                port = DEFAULT_PORT unless port
                [host,port]
            when Array
                address[0..1]
            end
        end
        
        def parse_options(options)
            @timeout = options.fetch(:timeout,DEFAULT_TIMEOUT)
            @max_connect_delay = options.fetch(:connect_delay,DEFAULT_CONNECT_DELAY)
            @connect_timeout = options.fetch(:connect_timeout,@timeout * 1.0 / 7.0)
        end

        def reconnect()
           
            #Rotate address
            host,port = @addresses.shift
            @addresses.push([host,port])

            delay = rand() * @max_connect_delay
            
            log.debug { "Connecting id=#{@session_id} to #{host}:#{port} with delay=#{delay}, timeout=#{@connect_timeout}" } 
            binding.connect(host,port,delay,@connect_timeout)
        end

       
        def session_expired()
           clear_pending_queue(:session_expired)
           
           invoke_response(*@close_packet.error(:session_expired)) if @close_packet

           if @client_state == :closed
              log.info { "Session closed id=#{@session_id}, keeper=:#{@keeper_state}, client=:#{@client_state}" }
           else
              log.warn { "Session expired id=#{@session_id}, keeper=:#{@keeper_state}, client=:#{@client_state}" }
           end

           @keeper_state = :expired
           @client_state = :closed
        end

        def complete_connection(response)
            result = Proto::ConnectResponse.read(response)
            if (result.time_out <= 0)
                #We're dead!
                session_expired()
            else
                timeout = result.time_out
                @keeper_state = :connected
                @ping_interval = (result.time_out / 1000).to_f * 2.0 / 7.0
                @session_id = result.session_id
                @session_passwd = result.passwd
                log.info { "Connected session_id=#{@session_id}, timeout=#{result.time_out}, ping=#{@ping_interval}" }

                log.debug { "Sending #{@pending_queue.length} queued packets" }
                @pending_queue.each { |p| send_packet(p) }
                
                queue_close_packet_if_necessary()
            end
        end
        
        def process_reply(packet_io)
              header = Proto::ReplyHeader.read(packet_io)
              log.debug { "Reply header: #{header.inspect}" }

              case header.xid.to_i
              when -2
                log.debug { "Ping reply" }
              when -4
                #TODO Auth reply (which may fail)
              when -1
                #Watch notification
                event = Proto::WatcherEvent.read(packet_io)
                process_watch_notification(event.state.to_i,event._type.to_i,event.path)
              else
                # A normal packet reply. They should come in the order we sent them
                # so we just match it to the packet at the front of the queue
                packet = @pending_queue.shift
                log.debug { "Reply packet: #{packet.inspect}" }

                if (packet.xid.to_i != header.xid.to_i)

                   log.error { "Bad XID! expected=#{packet.xid}, received=#{header.xid}" }

                   # Treat this like a dropped connection, and then force the connection
                   # to be dropped. But wait for the connection to notify us before
                   # we actually update our keeper_state
                   packet.error(:connection_lost)
                   @conn.disconnect() 
                else
                    @last_zxid_seen = header.zxid
                    
                    callback, response, watch_type  = packet.result(header.err.to_i)
                    log.debug { "Reply response: #{response.inspect}" } 
                    invoke_response(callback,response,packet_io)

                    @watches[watch_type][packet.path] << packet.watcher if (watch_type)
                    queue_close_packet_if_necessary()
                end
              end
        end
        

        def process_watch_notification(state,event,path)

            watch_types = WatchEvent.get(event).watch_types()

             watches = watch_types.inject(Set.new()) do | result, watch_type |
                result.merge(@watches[watch_type].delete(path))
             end

             watches.each do | watch |
                #TODO invoke with binding.invoke
                # and handle exceptions
                if watch.respond_to?(:process_watch)
                   watch.process_watch(state,event,path)
                elsif watch.respond_to?(:call)
                   watch.call(state,event,path)
                else
                   raise ProtocolError("Bad watcher #{watch}")
                end
             end
             
        end


        def clear_pending_queue(reason)
           @pending_queue.each  { |p| invoke_response(*p.error(reason)) }
           @pending_queue.clear
        end

        def queue_close_packet_if_necessary
            if @pending_queue.empty? && @keeper_state == :connected && @close_packet
                log.debug { "Sending close packet!" }
                @client_state = :closed
                queue_packet(@close_packet)
                @close_packet = nil
            end
        end

        def invoke_response(callback,response,packet_io = nil)
            if callback
                args = if response.respond_to?(:read) && packet_io
                    [response.read(packet_io)]
                elsif response
                    [response]
                else
                    []
                end
                binding.invoke(callback,*args)
            end
        end

        def resolve_watcher(watch_type,watcher)
            if watcher == true
                #the actual TrueClass refers to the default watcher
                watcher = @default_watcher
            elsif watcher.respond_to?(:call) || watcher.respond_to?(:process_watch)
                # ok a proc or quacks like a watcher
            elsif watcher
                # something, but not something we can handle
                raise ArgumentError, "Not a watcher #{watcher.inspect}"
            else
                watch_type = nil
            end
            [watch_type,watcher]
        end


        def queue_packet(packet)
            @pending_queue.push(packet)
            log.debug { "Queued: #{packet.inspect}" }

            if @keeper_state == :connected
                send_packet(packet)
            end
        end

        def next_xid
            @xid += 1
        end

        def send_packet(packet)
            records = [] << Proto::RequestHeader.new(:xid => packet.xid, :_type => packet.opcode)
            records << packet.request if packet.request
            @conn.send_records(*records)
        end


    end # Session
end
