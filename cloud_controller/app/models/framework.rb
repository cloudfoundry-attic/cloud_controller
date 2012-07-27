class Framework

  class << self

    def all
      frameworks.values
    end

    def find(framework_name)
      frameworks[framework_name]
    end

    private
    def frameworks
      @@frameworks ||= load_all_frameworks
    end

    def load_all_frameworks
      frameworks = {}
      pattern = File.join(AppConfig[:directories][:staging_manifests], '*.yml')
      Dir[pattern].each do |yaml_file|
        next if File.basename(yaml_file) == 'platform.yml'
        load_manifest(yaml_file, frameworks)
      end
      frameworks
    end

    def load_manifest(path, frameworks)
      framework_name = File.basename(path, '.yml')
      framework = YAML.load_file(path)
      unless framework['disabled']
        frameworks[framework_name] = Framework.new(framework)
      end
    rescue Exception=>e
      CloudController.logger.error "Failed to load staging manifest for #{framework_name} from #{path.inspect}.  Error: #{e}"
    end
  end

  attr_reader :name, :detection, :runtimes, :options

  def initialize(options={})
    @name = options["name"]
    @detection = options["detection"] || []
    @runtimes = options["runtimes"] || []
    @options = options
  end

  def default_runtime
    @runtimes.each do |rt|
      rt.each do |name, rt_info|
        return name if rt_info['default']
      end
    end
    return nil
  end

  def supports_runtime?(runtime_name)
    @runtimes.each do |runtime|
      return true if !runtime[runtime_name].nil?
    end
    false
  end
end
