class AppManager
  attr_reader :app

  class << self

    def pending
      @pending ||= []
    end

    def running
      @running ||= {}
    end
  end

  def initialize(app)
    @app = app
  end

  def health_manager_message_received(payload)
    CloudController.logger.debug("[HealthManager] Received #{payload[:op]} request for app #{app.id} - #{app.name}")

    indices = payload[:indices]
    message = new_message

    case payload[:op]
    when /START/i
      # Check if App is started.
      unless app.started?
        CloudController.logger.debug("[HealthManager] App no longer running, ignoring")
        return
      end
      # Only process start requests for current version.
      unless app.generate_version == payload[:version]
        CloudController.logger.debug("[HealthManager] Request for older version of app, ignoring")
        return
      end
      CloudController.logger.debug("[HealthManager] Starting #{indices.length} missing instances for app: #{app.id}")
      # FIXME - Check capacity

      message[:flapping] = true if payload[:flapping]
      indices.each { |i| start_instance(message, i) }
    when /STOP/i
      # If HM detects older versions, let's clean up here versus suppressing
      # and leaving old versions in the system. HM will start new ones if needed.
      if payload[:last_updated] == app.last_updated
        stop_msg = { :droplet => app.id, :instances => payload[:instances] }
        NATS.publish('dea.stop', Yajl::Encoder.encode(stop_msg))
      end
    when /SPINDOWN/i
      # Initial implementation simply stops the application,
      # as if a "vmc stop" command was issued.
      # Application would then need to be manually restarted.
      # "Spinup" semantics and implementation TBD.
      CloudController.logger.debug("[HealthManager] Spindown (stopping) app: #{app.id}")
      app.state = 'STOPPED'
      app.save!
      stop_all
    end
  end

  def once_app_is_staged
    elapsed = perform_deferred_app_operation(360.0) do |app|
      if app.staged? || app.staging_failed?
        yield
        true
      end
    end
  end

  def start_instances(start_message, index, max_to_start)
    EM.next_tick do
      f = Fiber.new do
        message = start_message.dup
        message[:executableUri] = download_app_uri(message[:executableUri])
        message[:debug] = @app.metadata[:debug]
        message[:console] = @app.metadata[:console]
        (index...max_to_start).each do |i|
          message[:index] = i
          dea_id = find_dea_for(message)
          json = Yajl::Encoder.encode(message)
          if dea_id
            CloudController.logger.debug("Sending start message #{json} to DEA #{dea_id}")
            NATS.publish("dea.#{dea_id}.start", json)
          else
            CloudController.logger.warn("No resources available to start instance #{json}")
          end
        end
      end
      f.resume
    end
  end

  def started
    once_app_is_staged do
      save_staged_app_state # Bumps runcount
      message = new_message
      # Start a single instance on staging failure to display staging errors to user
      num_to_start = app.staging_failed? ? 1 : app.instances
      start_instances(message, 0, num_to_start)
    end
  end

  def stopped
    stop_all
  end

  def change_running_instances(delta)
    return unless app.started?
    message = new_message
    if (delta > 0)
      start_instances(message, app.instances - delta, app.instances)
    else
      indices = (app.instances...(app.instances - delta)).collect { |i| i }
      stop_instances(indices)
    end
  end

  def update_uris
    return unless app.staged?
    message = new_message
    json = Yajl::Encoder.encode(message)
    NATS.publish('dea.update', json)
  end

  def updated
    once_app_is_staged do
      unless app.staging_failed?
        message = {
          :droplet => app.id,
          :cc_partition => AppConfig[:cc_partition]
        }
        NATS.publish('droplet.updated', Yajl::Encoder.encode(message))
      end
    end
  end

  def update_run_count
    if app.staged_package_hash_changed?
      app.run_count = 0 # reset
    else
      app.run_count += 1
    end
  end

  def save_staged_app_state
    update_run_count
    if !app.save
      errors = app.errors.full_messages
      CloudController.logger.warn("App #{app.id} was not valid after attempted staging: #{errors.join(',')}", :tags => [:staging])
    end
  end

  # Returns an array of hashes containing 'index', 'state', 'since'(timestamp),
  # 'debug_ip', and 'debug_port' for all instances running, or trying to run,
  # the app.
  def find_instances
    return [] unless app.started?
    instances = app.instances
    indices = []

    message = {
      :droplet => app.id,
      :version => app.generate_version,
      :state => :FLAPPING
    }

    flapping_indices_json = NATS.timed_request('healthmanager.status', message.to_json, :timeout => 2).first
    flapping_indices = Yajl::Parser.parse(flapping_indices_json, :symbolize_keys => true) rescue nil
    if flapping_indices && flapping_indices[:indices]
      flapping_indices[:indices].each do |entry|
        index = entry[:index]
        if index >= 0 && index < instances
          indices[index] = {
            :index => index,
            :state => :FLAPPING,
            :since => entry[:since]
          }
        end
      end
    end

    message = {
      :droplet => app.id,
      :version => app.generate_version,
      :states => ['STARTING', 'RUNNING']
    }

    expected_running_instances = instances - indices.length

    if expected_running_instances > 0
      opts = { :timeout => 2, :expected => expected_running_instances }
      running_instances = NATS.timed_request('dea.find.droplet', message.to_json, opts)
      running_instances.each do |instance|
        instance_json = Yajl::Parser.parse(instance, :symbolize_keys => true) rescue nil
        next unless instance_json
        index = instance_json[:index] || instances
        if index >= 0 && index < instances
          indices[index] = {
            :index => index,
            :state => instance_json[:state],
            :since => instance_json[:state_timestamp],
            :debug_ip => instance_json[:debug_ip],
            :debug_port => instance_json[:debug_port],
            :console_ip => instance_json[:console_ip],
            :console_port => instance_json[:console_port]
          }
        end
      end
    end

    instances.times do |index|
      index_entry = indices[index]
      unless index_entry
        indices[index] = { :index => index, :state => :DOWN, :since => Time.now.to_i }
      end
    end
    indices
  end

  def find_crashes
    crashes = []
    message = {:droplet => app.id, :state => :CRASHED}
    crashed_indices_json = NATS.timed_request('healthmanager.status', message.to_json, :timeout => 2).first
    crashed_indices = Yajl::Parser.parse(crashed_indices_json, :symbolize_keys => true) rescue nil
    crashes = crashed_indices[:instances] if crashed_indices
    crashes
  end

  # TODO, this should be calling one generic find_instances
  def find_specific_instance(options)
    message = { :droplet => app.id }
    message.merge!(options)
    instance_json = NATS.timed_request('dea.find.droplet', message.to_json, :timeout => 2).first
    instance = Yajl::Parser.parse(instance_json, :symbolize_keys => true) rescue nil
  end

  # TODO - This has a lot in common with 'find_instances'; at the very
  # least, the 'fill remaining slots with 'DOWN' instances' code should
  # be refactored out.
  def find_stats
    indices = {}
    return indices if (app.nil? || !app.started?)

    message = { :droplet => app.id, :version => app.generate_version,
                :states => ['RUNNING'], :include_stats => true }
    opt = { :timeout => 2, :expected => app.instances }
    running_instances = NATS.timed_request('dea.find.droplet', message.to_json, opt)

    running_instances.each do |instance|
      instance_json = Yajl::Parser.parse(instance, :symbolize_keys => true)
      index = instance_json[:index]
      if index >= 0 && index < app.instances
        indices[index] = {
          :state => instance_json[:state],
          :stats => instance_json[:stats]
        }
      end
    end

    app.instances.times do |index|
      index_entry = indices[index]
      unless index_entry
        indices[index] = {
          :state => :DOWN,
          :since => Time.now.to_i
        }
      end
    end

    indices
  end

  def download_app_uri(path)
    ['http://', "#{CloudController.bind_address}:#{CloudController.external_port}", path].join
  end


  # start_instance involves several moving pieces, from sending requests for help to the
  # dea_pool, to sending the actual start messages. In addition, many of these can be
  # triggered by one update call, so we simply queue them for the next go around through
  # the event loop with their own fiber context
  def start_instance(message, index)
    # Release any pending api call.
    EM.next_tick do
      wf = Fiber.new do
        message = message.dup
        message[:executableUri] = download_app_uri(message[:executableUri])
        message[:index] = index
        message[:debug] = @app.metadata[:debug]
        message[:console] = @app.metadata[:console]
        dea_id = find_dea_for(message)
        json = Yajl::Encoder.encode(message)
        if dea_id
          CloudController.logger.debug("Sending start message #{json} to DEA #{dea_id}")
          NATS.publish("dea.#{dea_id}.start", json)
        else
          CloudController.logger.warn("No resources available to start instance #{json}")
        end
      end
      wf.resume
    end
  end

  def find_dea_for(message)
    if AppConfig[:new_initial_placement]
     DEAPool.find_dea(message)
    else
      find_dea_message = {
        :droplet => message[:droplet],
        :limits => message[:limits],
        :name => message[:name],
        :runtime_info => message[:runtime_info],
        :runtime => message[:runtime],
        :prod => message[:prod],
        :sha => message[:sha1]
      }
      json_msg = Yajl::Encoder.encode(find_dea_message)
      result = NATS.timed_request('dea.discover', json_msg, :timeout => 2).first
      return nil if result.nil?
      CloudController.logger.debug "Received #{result.inspect} in response to dea.discover request"
      Yajl::Parser.parse(result, :symbolize_keys => true)[:id]
    end
  end

  def stop_instances(indices)
    stop_msg = { :droplet => app.id, :version => app.generate_version, :indices => indices }
    NATS.publish('dea.stop', Yajl::Encoder.encode(stop_msg))
  end

  def stop_all
    NATS.publish('dea.stop', Yajl::Encoder.encode(:droplet => app.id))
  end

  def get_file_url(instance, path=nil)
    raise CloudError.new(CloudError::APP_STOPPED) if app.stopped?

    search_options = {}

    if instance =~ /^\d{1,10}$/
      instance = instance.to_i
      if instance < 0 || instance >= app.instances
        raise CloudError.new(CloudError::APP_INSTANCE_NOT_FOUND, instance)
      end
      search_options[:indices] = [instance]
      search_options[:states] = [:STARTING, :RUNNING, :CRASHED]
      search_options[:version] = app.generate_version
    else
      search_options[:instance_ids] = [instance]
    end
    if instance = find_specific_instance(search_options)
      ["#{instance[:file_uri]}#{instance[:staged]}/#{path}", instance[:credentials]]
    end
  end

  def perform_deferred_app_operation(time_limit = 30.0)
    raise ArgumentError, "method requires a block" unless block_given?
    start_time = Time.now
    elapsed = 0.0
    should_exit = false
    until should_exit || elapsed > time_limit
      break unless app_still_exists?
      should_exit = yield(app)
      elapsed = (Time.now - start_time)
      fiber_sleep(0.5) unless should_exit
    end
    elapsed
  end

  def new_message
    data = {:droplet => app.id, :name => app.name, :uris => app.mapped_urls}
    data[:runtime] = app.runtime
    data[:runtime_info] = Runtime.find(app.runtime).options
    data[:framework] = app.framework
    data[:prod] = app.prod
    data[:sha1] = app.staged_package_hash
    data[:executableFile] = app.resolve_staged_package_path
    data[:executableUri] = "/staged_droplets/#{app.id}/#{app.staged_package_hash}"
    data[:version] = app.generate_version
    data[:services] = app.service_bindings.map {|sb| sb.for_dea }
    data[:limits] = app.limits
    data[:env] = app.environment_variables
    data[:users] = [app.owner.email]  # XXX - should we collect all collabs here?
    data[:cc_partition] = AppConfig[:cc_partition]
    data
  end

  def app_still_exists?
    @app && @app = App.uncached { App.find_by_id(@app.id) }
  end

  def fiber_sleep(secs)
    f = Fiber.current
    EM.add_timer(secs) { f.resume }
    Fiber.yield
  end
end
