
# This is a Fiber (1.9) aware extension.
module NATS
  class << self
    def timed_request(subject, data=nil, opts = {})
      expected = opts[:expected] || 1
      timeout  = opts[:timeout]  || 1
      f = Fiber.current
      results = []

      # Subscribe when at least one message is expected to be received
      if expected > 0
        sid = NATS.request(subject, data, :max => expected) do |msg|
          results << msg
          f.resume if results.length >= expected
        end
        NATS.timeout(sid, timeout, :expected => expected) { f.resume }
        Fiber.yield
      end

      return results.slice(0, expected)
    end
  end
end
