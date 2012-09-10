EM.next_tick do

  NATS.subscribe('dea.advertise') do |msg|
    begin
      payload = Yajl::Parser.parse(msg, :symbolize_keys => true)
    rescue => e
      CloudController.logger.error("Failed parsing DEA advertisement #{msg} : #{e}")
      CloudController.logger.error(e)
      next
    end

    CloudController::UTILITY_FIBER_POOL.spawn do
      begin
        DEAPool.process_advertise_message(payload)
      rescue => e
        CloudController.logger.error("Failed processing dea advertisement: '#{msg}'")
        CloudController.logger.error(e)
      end
    end
  end
  NATS.publish('dea.locate')
end
