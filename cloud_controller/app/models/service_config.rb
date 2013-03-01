require 'services/api'

# XXX - Need to move all apps using this config to pending
class ServiceConfig < ActiveRecord::Base
  belongs_to :user    # owner
  belongs_to :service

  has_many :service_bindings, :dependent => :destroy
  has_many :binding_tokens, :dependent => :destroy
  has_many :apps, :through => :service_bindings

  validates_presence_of :alias
  validates_uniqueness_of :alias, :scope => :user_id

  serialize :data
  serialize :credentials

  def self.provision(service, user, cfg_alias, plan, plan_option, version)

    # Ordering here is important. What follows each numbered operation
    # assumes that it failed.
    #
    # 0. Validate user input
    #    This is implemented by partially recording the state sans the service
    #    instance handle.
    #    If input is invalided, the change to state will be rolled back, and
    #    the exception will propagate back to the controller
    #
    # 1. Update the upstream gateway
    #    If the upstream gateway died before provisioning the request,
    #    then no state has changed and all is well. If the upstream died
    #    after provisioning our request, it is responsible for updating
    #    its local state after pulling the canonical state.
    #
    # 2. Update our local state
    #    If this goes wrong, we unprovision the instance created upstream and
    #    rollback the change. In this course more things can go wrong, in which
    #    case the upstream is responsible for deleting the dangling config
    #    the next time it pulls canonical state (since the state
    #    will lack the handle).

    transaction do
      svc_config = ServiceConfig.create!(
        :user_id     => user.id,
        :service_id  => service.id,
        :alias       => cfg_alias,
        :plan        => plan,
        :plan_option => plan_option
      )
      req = VCAP::Services::Api::GatewayProvisionRequest.new(
        :label => service.label,
        :name  => cfg_alias,
        :email => user.email,
        :plan  => plan,
        :plan_option => plan_option,
        :version => version
      )

      client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
      begin
        config = client.provision req.extract
      rescue => e
        CloudController.logger.error("Error talking to gateway: #{e}")
        CloudController.logger.error(e)
        raise CloudError.new(CloudError::SERVICE_GATEWAY_ERROR)
      end
      svc_config.attributes = {
        :data           => config.configuration,
        :credentials    => config.credentials,
        :name           => config.service_id
      }
      begin
        svc_config.save!
        return svc_config
      rescue => e
        unprovision(service, config.service_id)
        raise
      end
    end
  end

  def self.unprovision(service, service_id)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.unprovision(:service_id => service_id)
  rescue => e
    CloudController.logger.error("Error talking to gateway: #{e}")
    CloudController.logger.error(e)
    raise CloudError.new(CloudError::SERVICE_GATEWAY_ERROR)
  end

  def unprovision
    # Destroy our copy first. Order here is important. What follows each
    # numbered operation assumes that the operation failed.
    #
    # 1. Destroy the local config
    #    No state (local or upstream) has been altered. All is well.
    #
    # 2. Destroy the remote config
    #    The service provider will be responsible for destroying the remote
    #    config the next time they fetch canonical state.

    destroy

    ServiceConfig.unprovision(service, name)
  end

  def handle_sds_error(e)
    CloudController.logger.error("Error talking to serialization_data_server: #{e}")
    CloudController.logger.error(e)
    raise CloudError.new(CloudError::SDS_ERROR, "#{e.message}")
  end

  def handle_lifecycle_error(e)
    CloudController.logger.error("Error talking to gateway: #{e}")
    CloudController.logger.error(e)
    if e.is_a? VCAP::Services::Api::ServiceGatewayClient::ErrorResponse
      raise CloudError.new([e.error.code, e.status, e.error.description])
    else
      raise CloudError.new(CloudError::SERVICE_GATEWAY_ERROR)
    end
  end

  def create_snapshot
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.create_snapshot(:service_id => name)
  rescue => e
    handle_lifecycle_error(e)
  end

  def enum_snapshots
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.enum_snapshots(:service_id => name)
  rescue => e
    handle_lifecycle_error(e)
  end

  def snapshot_details(sid)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.snapshot_details(:service_id => name, :snapshot_id => sid)
  rescue => e
    handle_lifecycle_error(e)
  end

  def update_snapshot_name(sid, req)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.update_snapshot_name(:service_id => name, :snapshot_id => sid, :msg => req)
  rescue => e
    handle_lifecycle_error(e)
  end

  def rollback_snapshot(sid)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.rollback_snapshot(:service_id => name, :snapshot_id => sid)
  rescue => e
    handle_lifecycle_error(e)
  end

  def delete_snapshot(sid)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.delete_snapshot(:service_id => name, :snapshot_id => sid)
  rescue => e
    handle_lifecycle_error(e)
  end

  def serialized_url(sid)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.serialized_url(:service_id => name, :snapshot_id => sid)
  rescue => e
    handle_lifecycle_error(e)
  end

  def create_serialized_url(sid)
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.create_serialized_url(:service_id => name, :snapshot_id => sid)
  rescue => e
    handle_lifecycle_error(e)
  end

  def import_from_url req
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.import_from_url(:service_id => name, :msg => req)
  rescue => e
    handle_lifecycle_error(e)
  end

  def import_from_data req
    client = VCAP::Services::Api::SDSClient.new(req[:upload_url], req[:upload_token], req[:upload_timeout])
    client.import_from_data(:service =>service.name , :service_id => name, :msg => req[:data_file_path])
  rescue => e
    handle_sds_error(e)
  end

  def job_info job_id
    client = VCAP::Services::Api::ServiceGatewayClient.new(service.url, service.token, service.timeout)
    client.job_info(:service_id => name, :job_id => job_id)
  rescue => e
    handle_lifecycle_error(e)
  end

  def provisioned_by?(user)
    (self.user_id == user.id)
  end

  # Returned for calls from legacy clients
  def as_legacy
    { :name       => self.alias,
      :service_id => self.name,
      :type       => self.service.synthesize_service_type,
      :vendor     => self.service.name,
      :provider   => self.service.provider || "core",
      # backward compatible, service.version will be removed in the future.
      :version    => self.data && self.data["version"] || self.service.version,
      :tier       => self.plan,
      :properties => self.service.binding_options || {},
      :meta => {
        :created => self.created_at.to_i,
        :updated => self.updated_at.to_i,
        :tags    => self.service.tags || [],
        :version => 1 # This no longer exists, just here for completeness
      },
    }
  end

  # generate correct label for backward compatible concern.
  # the 'label' field will be removed in the future.
  def get_label
    version = data["version"]
    if version
      "#{service.name}-#{version}"
    else
      # old instance
      service.label
    end
  end

  def get_tags
    svc = self.service
    tags = svc.tags.clone
    tags << get_label
    tags << svc.name
    tags
  end
end
