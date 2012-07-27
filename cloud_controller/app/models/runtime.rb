class Runtime

  class << self

    def all
      runtimes.values
    end

    def find(runtime_name)
      runtimes[runtime_name]
    end

    private
    def runtimes
      @@runtimes ||= load_runtimes
    end

    def load_runtimes
      runtimes = {}
      begin
        runtimes_info = YAML.load_file(AppConfig[:runtimes_file])
        runtimes_info.each_pair do |runtime_name, runtime_info|
          runtimes[runtime_name] = Runtime.new(runtime_name, runtime_info) unless runtime_info['disabled']
        end
      rescue Exception=>e
        CloudController.logger.error "Unable to parse runtime file from #{AppConfig[:runtimes_file].inspect}.  Error: #{e}"
      end
      runtimes
    end
  end

  attr_reader :name, :version, :description, :debug_modes, :options

  def initialize(name, options={})
    @name = name
    @version = options["version"]
    @description = options["description"]
    @debug_modes = options["debug_modes"]
    @options = options
    @options["name"] = name
  end
end
