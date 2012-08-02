class ServiceBinding < ActiveRecord::Base
  belongs_to :service_config
  belongs_to :app
  belongs_to :user
  belongs_to :binding_token

  validates_presence_of :name
  validates_uniqueness_of :service_config_id, :scope => :app_id

  serialize :configuration
  serialize :credentials
  serialize :binding_options

  # Return an entry that will be stored in the :services key
  # of the staging environment.
  # The returned keys are:
  # :label, :name, :credentials, :options
  def for_staging
    data = {}
    cfg = service_config
    svc = cfg.service
    data[:label] = get_label
    data[:tags] = svc.tags
    data[:name] = cfg.alias # what the user chose to name it
    data[:credentials] = credentials
    data[:options] = binding_options # options specified at bind-time
    data[:plan] = cfg.plan
    data[:plan_option] = cfg.plan_option
    data
  end

  # return the message that used by dea to forge the
  # service related environment variables
  def for_dea_message
    cfg = service_config
    svc = cfg.service
    { :name    => cfg.alias,
      :type    => svc.synthesize_service_type,
      :label   => sb.get_label,
      :vendor  => svc.name,
      :version => svc.version,
      :tags    => svc.tags,
      :plan    => cfg.plan,
      :plan_option => cfg.plan_option,
      :credentials => sb.credentials,
    }
  end

  def get_label
    version = service_config.data["version"]
    if version
      "#{service_config.service.name}-#{version}"
    else
      # old instance
      service_config.service.label
    end
  end
end
