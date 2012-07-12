require "fiber"
require "active_record"
require "active_record/base"

class Fiber
  alias :initialize_without_patch :initialize

  def initialize(*args, &blk)
    patched_blk = lambda do |*args|
      begin
        blk.call(*args)
      ensure
        blk = Fiber.current[:__active_record_cleanup]
        blk.call if blk
      end
    end

    initialize_without_patch(*args, &patched_blk)
  end
end

module ActiveRecord
  module ConnectionAdapters
    class ConnectionPool
      def connection
        @reserved_connections[current_connection_id] ||= checkout
      end

      def current_connection_id
        Fiber.current.object_id
      end

      def clear_stale_cached_connections!
        nil
      end

      def checkout
        conn = if @checked_out.size < @connections.size
          checkout_existing_connection
        else
          # Everything is checked out
          checkout_new_connection
        end

        Fiber.current[:__active_record_cleanup] = lambda do
          checkin conn
        end

        _connection_logging('checkout')

        conn
      end

      def checkin(conn)
        @reserved_connections.delete current_connection_id
        @checked_out.delete conn

        _connection_logging('checkin')
      end

      private

      def _connection_logging(msg)
        if CloudController.logger
          CloudController.logger.info \
            "%s connections: %d/%d" % \
            [ msg, @checked_out.size, @connections.size ]
        end
      end
    end
  end
end
