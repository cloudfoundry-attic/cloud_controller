class DefaultController < ApplicationController
  def info
    info = {
      :name        => 'vcap',
      :build       => 2222,
      :support     => AppConfig[:support_address],
      :version     => CloudController.version,
      :description => AppConfig[:description],
      :allow_debug => AppConfig[:allow_debug],
      :frameworks  => frameworks_info,
    }

    if uaa_enabled?
      info[:authorization_endpoint] = (AppConfig[:login] && AppConfig[:login][:url]) ? AppConfig[:login][:url] : AppConfig[:uaa][:url]
    end

    # If there is a logged in user, give out additional information
    if user
      info[:user]   = user.email
      info[:limits] = user.account_capacity
      info[:usage]  = user.account_usage
    end

    render :json => info
  end

  def runtime_info
    render :json => runtimes_info
  end

  def service_info
    svcs = Service.active_services.select { |svc| svc.visible_to_user?(user) }
    CloudController.logger.debug("Global service listing found #{svcs.length} services.")

    ret = {}
    svc_count = Hash.new(0)
    svcs.each do |svc|
      svc_count[svc.name] = svc_count[svc.name] + 1
    end

    svcs.each do |svc|
      # Just return core services or the service with only one provider
      if svc.provider.nil? || svc.provider == "core" || svc_count[svc.name] == 1
        svc_type = svc.synthesize_service_type
        ret[svc_type] ||= {}
        ret[svc_type][svc.name] ||= {}

        versions = svc.supported_versions
        versions.each do |version|
          version_alias = svc.version_to_alias(version)
          next if (versions.size > 1 && version_alias != "current")

          svc_desc = svc.as_legacy(user)
          svc_desc[:version] = version
          svc_desc[:alias] = version_alias if version_alias
          ret[svc_type][svc.name][version] = svc_desc
        end
      end
    end

    render :json => ret
  end

  def index
    if AppConfig[:index_page]
      redirect_to AppConfig[:index_page]
    else
      render :text => "Welcome to VMware's Cloud Application Platform\n"
    end
  end

  def not_implemented
    $stderr.puts "\nNOT IMPLEMENTED: #{request.fullpath} #{request.body.read}"
    render :json => {"error" => "Not yet implemented"}
  end

  # be fairly quiet on bad routes
  def route_not_found
    render :nothing => true, :status => :not_found
  end

  private
  def frameworks_info
    @frameworks_info ||= generate_frameworks_info
  end

  def runtimes_info
    @runtime_info ||= generate_runtimes_info
  end

  def generate_frameworks_info
    frameworks_info = {}
    Framework.all.each do |framework|
      runtimes = []
      framework.runtimes.each do |runtime|
        runtime.each_pair do |runtime_name, runtime_info|
          runtime_info = Runtime.find(runtime_name)
          if runtime_info
            runtimes <<  {
              :name => runtime_name,
              :version => runtime_info.version,
              :description => runtime_info.description}
          else
            CloudController.logger.warn("Manifest for #{framework.name} lists a runtime not present in " +
              "runtimes.yml: #{runtime_name}.  Runtime will be skipped.")
          end
        end
      end
      f = {
        :name => framework.name,
        :runtimes => runtimes,
        :detection => framework.detection
      }
      frameworks_info[framework.name] = f
    end
   frameworks_info
  end

  def generate_runtimes_info
    runtime_info = {}
    Runtime.all.each do |runtime|
      runtime_info[runtime.name] = {
        :version => runtime.version,
        :description => runtime.description,
        :debug_modes=> runtime.debug_modes }
    end
    runtime_info
  end
end
