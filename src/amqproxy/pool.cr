require "openssl"

module AMQProxy
  class Pool
    getter :size
    @tls_ctx : OpenSSL::SSL::Context::Client?

    def initialize(@host : String, @port : Int32, tls : Bool, @log : Logger, @idle_connection_timeout : Int32, @max_pool_size : Int32)
      @pools = Hash(Tuple(String, String, String), Deque(Upstream)).new do |h, k|
        h[k] = Deque(Upstream).new
      end
      @lock = Mutex.new
      @size = 0
      @tls_ctx = OpenSSL::SSL::Context::Client.new if tls
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    def borrow(user : String, password : String, vhost : String, client : Client, &block : Upstream -> _)
      u = @lock.synchronize do
        c = @pools[{user, password, vhost}].pop?
        if c.nil? || c.closed?
          @log.debug("Pool size: #{@size}/#{@max_pool_size}")
          # no pool limit (-1) or limit new upstream connections
          if @max_pool_size < 0 || (@max_pool_size > 0 && @size < @max_pool_size)
            c = Upstream.new(@host, @port, @tls_ctx, @log).connect(user, password, vhost)
            @size += 1
          else
            @log.error "Max upstream connections reached. Pool size: #{@size}/#{@max_pool_size}"
            raise Upstream::MaxConnectionError.new("Max upstream connections reached. Pool size: #{@size}/#{@max_pool_size}")
          end
        end
        c.current_client = client
        c
      end

      yield u
    ensure
      @lock.synchronize do
        if u.nil?
          @size -= 1
          @log.error "Upstream connection could not be established"
        elsif u.closed?
          @size -= 1
          @log.error "Upstream connection closed when returned"
        else
          u.client_disconnected
          u.last_used = Time.monotonic
          @pools[{user, password, vhost}].push u
        end
      end
    end

    def close
      @lock.synchronize do
        @pools.each_value do |q|
          while u = q.shift?
            begin
              u.close "AMQProxy shutdown"
            rescue ex
              @log.error "Problem closing upstream: #{ex.inspect}"
            end
          end
        end
        @size = 0
      end
    end

    private def shrink_pool_loop
      loop do
        sleep 5.seconds
        @lock.synchronize do
          max_connection_age = Time.monotonic - @idle_connection_timeout.seconds
          @pools.each_value do |q|
            q.size.times do
              u = q.shift
              if u.last_used < max_connection_age
                @size -= 1
                begin
                  u.close "Pooled connection closed due to inactivity"
                rescue ex
                  @log.error "Problem closing upstream: #{ex.inspect}"
                end
              elsif u.closed?
                @size -= 1
                @log.error "Removing closed upstream connection from pool"
              else
                q.push u
              end
            end
          end
        end
      end
    end
  end
end
