require 'socket'
require 'thread'
require 'monitor'

# Binding over standard ruby sockets
#
# Manages 3 threads per zookeeper session
#
# Read thread
#   manages connecting to and reading from the tcp socket. Uses non blocking io to manage timeouts
#   and initiate the required ping requests.
#
# Write thread
#   each new connection spawns a new thread. Requests coming from the session in response
#   to multiple threads are written to a blocking queue. While the connection is alive
#   this thread reads from the queue and writes to the socket, all in blocking fashion
#   TODO: Is it really ok to do a non-blocking read during a blocking write?
# 
# Event thread
#   All response and watch callbacks are put on another blocking queue to be read and executed
#   by this thread.
#
# All interaction with the session is synchronized
#
# Client synchronous code is implemented with a condition variable that waits on the callback/errback 
module ZooKeeper::RubyIO
  
  class Connection
    include ZooKeeper::Protocol
    include Slf4r::Logger
    include Socket::Constants
    
    def initialize(host,port,timeout,session)
      @session = session
      @write_queue = Queue.new()

      # JRuby cannot do non-blocking connects, which means there is
      # no way to properly implement the connection-timeout
      # See http://jira.codehaus.org/browse/JRUBY-5165 
      # In any case this should be encapsulated in TCPSocket.open(host,port,timeout)
      if RUBY_PLATFORM == "java"
        sock = TCPSocket.new(host,port.to_i)
      else
        addr = Socket.getaddrinfo(host, nil)
        sock = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
        sock.setsockopt(SOL_SOCKET, SO_LINGER, [0,-1].pack("ii"))
        sock.setsockopt(SOL_TCP, TCP_NODELAY,[0].pack("i_"))
        sockaddr = Socket.pack_sockaddr_in(port, addr[0][3])
        begin
          sock.connect_nonblock(sockaddr)
        rescue Errno::EINPROGRESS
          resp = IO.select(nil, [sock], nil, timeout)
          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::ECONNREFUSED
            logger.warn("Connection refused to #{ host }:#{ port }")
            sock = nil
          rescue Errno::EISCONN
          end
        end
      end
      @socket = sock
      Thread.new() { write_loop(sock) } if sock
    end
    
    # This is called from random client threads, but only within
    # a @session.synchronized() block
    def send_data(data)
      @write_queue.push(data)
    end
    
    # Since this runs in its very own thread
    # we can use boring blocking IO
    def write_loop(socket)
      begin
        while socket
          data = @write_queue.pop()
          if socket.write(data) != data.length()
            #TODO - will this really ever happen
            logger.warn("Incomplete write!")
          end
          logger.debug { "Sending: " + data.unpack("H*")[0] }
        end
      rescue Exception => ex
        logger.warn("Exception in write loop",ex)
        disconnect()
      end
      
    end
    
    def read_loop()
      socket = @socket
      ping = 0
      while socket # effectively forever
        begin
          data = socket.read_nonblock(1024)
          receive_data(data)
          ping = 0
        rescue IO::WaitReadable
          select_result = IO.select([socket],[],[],@session.ping_interval)
          unless select_result
            ping += 1
            # two timeouts in a row mean we need to send a ping
            case ping
            when 1 ; @session.synchronize { @session.ping() }
            when 2
                logger.debug{"No response to ping in #{@session.ping_interval}*2"}
                break
            end
          end
        rescue EOFError
          logger.debug { "EOF reading from socket" }
          break
        rescue Exception => ex
          logger.warn( "#{ex.class} exception in readloop",ex )
          break
        end
      end
      disconnect()
    end
    
    def disconnect()
      socket = @socket
      @socket = nil
      socket.close if socket
    rescue Exception => ex
      #oh well
      logger.debug("Exception closing socket",ex)
    end
    
    # Protocol requirement
    def receive_records(packet_io)
      @session.synchronize { @session.receive_records(packet_io) }
    end
    
  end #Class connection
  
  class Binding
    include Slf4r::Logger
    attr_reader :session
    def self.available?
      true
    end
    def initialize()
      @event_queue = Queue.new()
    end
    
    def start(session)
      @session = session
      @session.extend(MonitorMixin)
      
      # start the event thread
      Thread.new() do
        loop do
          begin
            queued = @event_queue.pop()
            break unless queued
            callback,*args = queued
            callback.call(*args)
          rescue Exception => ex
            logger.warn( "Exception in event thread", ex )
          end
        end
      end
     
      # and the read thread
      Thread.new() do
        begin
          conn = session.synchronize { session.start(); session.conn() } # will invoke connect 
          loop do
            break unless conn
            conn.read_loop()
            conn =  session.synchronize { session.disconnected(); session.conn() }
          end
          #event of death
          logger.debug("Pushing nil (event of death) to event queue")
          @event_queue.push(nil)
        rescue Exception => ex
          logger.error( "Exception in session thread", ex )
        end
      end
    end
    
    # session callback, IO thread
    def connect(host,port,delay,timeout)
      sleep(delay)
      conn = Connection.new(host,port,timeout,session)
      session.synchronize() { session.prime_connection(conn) }
    end

    def synchronous_call(client,method,*args)
      mutex = Monitor.new
      cv = mutex.new_cond
      op_result = nil
      
      mutex.synchronize do
        op = client.send(method,*args) do |*results|
          mutex.synchronize do
            op_result = results
            cv.signal()
          end
        end
        
        op.errback do |err|
          mutex.synchronize do
            op_result  = ZooKeeperError.new(err)
            cv.signal()
          end
        end
        #Block until either our callback or errback is invoked on the event thread
        cv.wait()
      end
      
      if op_result.kind_of?(ZooKeeperError)
        message = "rc=#{ op_result.err }(:#{ op_result.err_name }) for ##{ method }(#{ args.join(',') })"
        raise op_result, message, caller[0..-1]
      end
      
      return op_result
    end
    
    def close(&blk)
      session.synchronize { session.close(&blk) }
    end
    
    def queue_request(*args,&blk)
      session.synchronize { session.queue_request(*args,&blk) }
    end
    
    def invoke(*args)
      # callback on the event thread
      @event_queue.push(args)
    end

  end #Binding
end #ZooKeeper
# Add our binding
ZooKeeper::BINDINGS << ZooKeeper::RubyIO::Binding
