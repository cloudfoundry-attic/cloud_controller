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
    data[:label] = cfg.get_label
    data[:tags] = cfg.get_tags
    data[:name] = cfg.alias # what the user chose to name it
    data[:credentials] = credentials
    data[:options] = binding_options # options specified at bind-time
    data[:plan] = cfg.plan
    data[:plan_option] = cfg.plan_option
    data[:type] = svc.synthesize_service_type
    data[:version] = svc.version
    data[:vendor] = svc.name
    data
  end

  alias :for_dea :for_staging
end
