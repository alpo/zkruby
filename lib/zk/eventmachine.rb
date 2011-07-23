
require 'eventmachine'
#require 'fiber'
module ZooKeeper
   module EventMachine
    
     def self.connect(addresses,options,&blk)
         session = Session.new(addresses,options)
         session.connection_factory = ConnectionFactory
         session.start(&blk)
         Client.new(session)
         Fiber.new(blk).resume(session) if block_given?
         return 
     end

     class ClientConn < ::EM::Connection
        include Protocol
        
        def initialize(session,connect_timeout)
            @session = session
            @connect_timeout = connect_timeout
            set_pending_connect_timeout(connect_timeout)
            rescue Exception => ex
                puts ex.message
        end

        def post_init()
            rescue Exception => ex
                puts ex.message
        end

        def connection_completed()
            @session.prime_connection(self)
           
            # Make sure we connect within the timeout period
            # TODO this should really be the amount of connect timeout left over
            @timer = EM.add_timer(@connect_timeout) do
                if @session.connected?
                    # Start the ping timer 
                    ping = @session.ping_interval
                    puts "Starting ping timer #{ping}"
                    @timer = EM.add_periodic_timer ( ping ) do
                        case @ping
                           when 1 then @session.ping()
                           when 2 then close_connection()
                        end
                        @ping += 1
                    end
                else
                    close_connection()
                end
            end

            rescue Exception => ex
                puts ex.message
        end

        def receive_records(packet_io)
            @ping = 0
            @session.receive_records(packet_io)
        end

        def disconnect()
            close_connection()
        end

        def unbind
            EM.cancel_timer(@timer) if @timer
            @session.disconnected()
            rescue Exception => ex
                puts ex.message
        end
    
     end

   
     # The EventMachine binding is very simple because there is only one thread!
     # and we have good stuff like timers provided for us
     class Binding
        # We can use this binding if we are running in the reactor thread
        def self.available?()
            EM.reactor_running? && EM.reactor_thread?
        end

        attr_reader :session
        def start(session)
            @session = session
            @session.start()
        end

        # After delay seconds create a connection to host:port
        # Once ready callback session.prime_connection(conn)
        # If socket is not ready to accept data within timeout seconds then callback session.disconnect()
        # @param host
        # @param port
        # @param delay - connection delay in seconds
        # @param timeout - the connection timeout in seconds
        # @param session - the session object to callback
        def connect(host,port,delay,timeout)
            EM.add_timer(delay) do
                EM.connect(host,port,ZooKeeper::EventMachine::ClientConn,@session,timeout)
            end
        end

        # You are working in event machine it is up to you to ensure your callbacks do not block
        def invoke(callback,*args)
            callback.call(*args)
        end

        def queue_request(*args,&blk)
            @session.queue_request(*args,&blk)
        end

        def synchronous_call(client,method,*args)
            f = Fiber.current
            
            op = client.send(method,*args) do |*results|
                f.resume(*results)
            end

            op.errback do |err|
                    f.resume(ZooKeeperError.new(err))
            end

            result = Fiber.yield
            if result.kind_of?(ZooKeeperError)
                message = "rc=#{result.err}(:#{result.err_name}) for ##{method}(#{args.join(',')})"  
                raise result, message, caller[0..-1]
            end
            return result
        end

        def close(&blk)
            @session.close(&blk)
        end
     end

  end #module ZooKeeper::EventMachinas
end #module ZooKeeper

ZooKeeper::BINDINGS << ZooKeeper::EventMachine::Binding