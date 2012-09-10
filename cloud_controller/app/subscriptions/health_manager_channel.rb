EM.next_tick do

  # Create a command channel for the Health Manager to call us on
  # when they are requesting state changes to the system.
  # All CloudControllers will form a queue group to distribute
  # the requests.
  # NOTE: Currently it is assumed that all CloudControllers are
  # able to command the system equally. This will not be the case
  # if the staged application store is not 'shared' between all
  # CloudControllers.

  NATS.subscribe("cloudcontrollers.hm.requests.#{AppConfig[:cc_partition]}", :queue => :cc) do |msg|
    begin
      payload = Yajl::Parser.parse(msg, :symbolize_keys => true)
    rescue => e
      CloudController.logger.error("Failed parsing HM request #{msg} : #{e}")
      CloudController.logger.error(e)
      next
    end

    CloudController::UTILITY_FIBER_POOL.spawn do
      begin
        App.process_health_manager_message(payload)
      rescue => e
        CloudController.logger.error("Failed processing HM request #{msg}: #{e}")
        CloudController.logger.error(e)
      end
    end
  end

end
