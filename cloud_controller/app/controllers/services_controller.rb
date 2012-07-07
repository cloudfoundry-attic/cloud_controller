require 'fileutils'
require 'json_message'
require 'uri'
require 'date'
require 'services/api'

# TODO(mjp): Split these into separate controllers (user facing vs gateway facing, along with tests)

class ServicesController < ApplicationController
  include ServicesHelper

  before_filter :validate_content_type, :except => [:import_from_data]
  before_filter :require_service_auth_token, :only => [:create, :get, :delete, :update_handle, :list_handles, :list_brokered_services]
  before_filter :require_sds_auth_token, :only => [:register_sds]
  before_filter :require_user, :only => [:provision, :bind, :bind_external, :unbind, :unprovision,
                                         :create_snapshot, :enum_snapshots, :snapshot_details,:rollback_snapshot, :delete_snapshot,
                                         :serialized_url, :create_serialized_url, :import_from_url, :import_from_data, :job_info]
  before_filter :require_lifecycle_extension, :only => [:create_snapshot, :enum_snapshots, :snapshot_details,:rollback_snapshot, :delete_snapshot,
                                         :serialized_url, :create_serialized_url, :import_from_url, :register_sds, :import_from_data, :job_info]
  before_filter :unify_provider, :only => [:get, :delete, :update_handle, :list_handles]

  rescue_from(JsonMessage::Error) {|e| render :status => 400, :json =>  {:errors => e.to_s}}
  rescue_from(ActiveRecord::RecordInvalid) {|e| render :status => 400, :json =>  {:errors => e.to_s}}

  # List all the offerings
  def list
    svcs = Service.active_services.select {|svc| svc.visible_to_user?(user)}
    CloudController.logger.debug("Global service listing found #{svcs.length} services.")

    ret = {}
    svcs.each do |svc|
      svc_type = svc.synthesize_service_type
      ret[svc_type] ||= {}
      ret[svc_type][svc.name] ||= {}
      svc_provider = svc.provider || "core"
      ret[svc_type][svc.name][svc_provider] ||= {}
      ret[svc_type][svc.name][svc_provider][svc.version] ||= {}
      ret[svc_type][svc.name][svc_provider][svc.version] = svc.hash_to_service_offering
    end

    render :json => ret
  end

  # Registers a new service offering with the CC
  #
  def create
    req = VCAP::Services::Api::ServiceOfferingRequest.decode(request_body)
    CloudController.logger.debug("Create service request: #{req.extract.inspect}")

    # Should we worry about a race here?

    success = nil
    svc = Service.find_by_label_and_provider(req.label, req.provider == "core" ? nil : req.provider)
    if svc
      raise CloudError.new(CloudError::FORBIDDEN) unless svc.verify_auth_token(@service_auth_token)
      attrs = req.extract.dup
      attrs.delete(:label)
      # Keep DB in sync with configs if the token changes in the config
      attrs[:token] = @service_auth_token if svc.is_builtin?
      # Special support for changing a service offering's ACLs from
      # private to public. The call to ServiceOfferingRequest.decode
      # (actually, JsonMessage.from_decoded_json) discards keys with
      # nil values, which is the case for key :acls when switching
      # from private to public.  This issue is more general than just
      # :acls, but to avoid breaking anything as a side efffect, we do
      # this only for :acls.
      #
      # Similar to acls, timeout, provider, supported_versions
      # and version_aliases attributes
      %w(acls timeout provider supported_versions version_aliases).each do |k|
        k = k.to_sym
        attrs[k] = nil unless attrs.has_key?(k)
      end
      attrs[:provider] = nil if attrs[:provider] == "core"

      svc.update_attributes!(attrs)
    else
      # Service doesn't exist yet. This can only happen for builtin services since service providers must
      # register with us to get a token.
      # or, it's a brokered service
      svc = Service.new(req.extract)
      if AppConfig[:service_broker] and \
         AppConfig[:service_broker][:token].index(@service_auth_token) and \
         !svc.is_builtin?
        attrs = req.extract.dup
        attrs[:token] = @service_auth_token
        svc.update_attributes!(attrs)
      else
        raise CloudError.new(CloudError::FORBIDDEN) unless svc.is_builtin? && svc.verify_auth_token(@service_auth_token)
        svc.token = @service_auth_token
        svc.provider = nil if svc.provider == "core"
        svc.save!
      end
    end

    render :json => {}
  end

  # Updates given handle with the new config.
  # XXX: This is REALLY inefficient...
  #
  def update_handle
    handle = VCAP::Services::Api::HandleUpdateRequest.decode(request_body)

    # We have to check two places here: configs and bindings :/
    if cfg = ServiceConfig.find_by_name(handle.service_id)
      raise CloudError.new(CloudError::FORBIDDEN) unless cfg.service.verify_auth_token(@service_auth_token)
      cfg.data = handle.configuration
      cfg.credentials = handle.credentials
      cfg.save!
    elsif bdg = ServiceBinding.find_by_name(handle.service_id)
      svc = bdg.service_config.service
      raise CloudError.new(CloudError::FORBIDDEN) unless (svc && (svc.verify_auth_token(@service_auth_token)))
      bdg.configuration = handle.configuration
      bdg.credentials = handle.credentials
      bdg.save!
    end

    raise CloudError.new(CloudError::BINDING_NOT_FOUND) unless (cfg || bdg)

    render :json => {}
  end

  # Returns the provisioned and bound handles for a service provider
  def list_handles
    svc = Service.find_by_label_and_provider(params[:label], params[:provider])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless svc
    raise CloudError.new(CloudError::FORBIDDEN) unless svc.verify_auth_token(@service_auth_token)

    handles = []
    cfgs = svc.service_configs
    if cfgs
      cfgs.each do |cfg|
        handles << {
          :service_id => cfg.name,
          :configuration => cfg.data,
          :credentials   => cfg.credentials
        }
      end
    end

    bdgs = svc.service_bindings
    if bdgs
      bdgs.each do |bdg|
        handles << {
          :service_id => bdg.name,
          :configuration => bdg.configuration,
          :credentials   => bdg.credentials,
        }
      end
    end

    render :json => {:handles => handles}
  end

  # List brokered services
  def list_brokered_services
    if AppConfig[:service_broker].nil? or \
       AppConfig[:service_broker][:token].index(@service_auth_token).nil?
      raise CloudError.new(CloudError::FORBIDDEN)
    end

    result = Service.where(:token => @service_auth_token)
    result = result.select { |svc| !svc.is_builtin? }
    result = result.map { |svc| {:label => svc.label, \
                  :description => svc.description, :acls => svc.acls } }

    render :json =>  {:brokered_services => result}
  end

  # Get a service offering on the CC
  #
  def get
    svc = Service.find_by_label_and_provider(params[:label], params[:provider])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless svc
    raise CloudError.new(CloudError::FORBIDDEN) unless svc.verify_auth_token(@service_auth_token)
    render :json => svc.hash_to_service_offering
  end

  # Unregister a service offering with the CC
  #
  def delete
    svc = Service.find_by_label_and_provider(params[:label], params[:provider])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless svc
    raise CloudError.new(CloudError::FORBIDDEN) unless svc.verify_auth_token(@service_auth_token)

    svc.destroy

    render :json => {}
  end

  # Asks the gateway to provision an instance of the requested service
  #
  def provision
    req = VCAP::Services::Api::CloudControllerProvisionRequest.decode(request_body)

    svc = Service.find_by_label_and_provider(req.label, req.provider == "core" ? nil : req.provider)
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless svc && svc.visible_to_user?(user, req.plan)

    # override version in label if version is given in request.
    # We support following Provision request and provision version 2.0 instance.
    # {'label' => 'Service-1.0', 'version' => '2.0'}
    # In the future, version info will be removed from label.
    version = nil
    if req.version
      # translate alias to version in request
      version = svc.version_aliases[req.version.to_s] || req.version
      raise CloudError.new(CloudError::UNSUPPORTED_VERSION, req.version) unless svc.support_version? version
    end

    # backward compatible, svc.version will be removed.
    version ||= svc.version
    cfg = ServiceConfig.provision(svc, user, req.name, req.plan, req.plan_option, version)

    handle = {
      :service_id  => cfg.name,
      :data        => cfg.data,
      :credentials => cfg.credentials,
    }
    render :json => handle
  end

  # Deletes a previously provisioned instance of a service
  #
  def unprovision
    cfg = ServiceConfig.find_by_user_id_and_alias(user.id, params[:id])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    cfg.unprovision

    render :json => {}
  end

  # Create a snapshot for service instance
  #
  def create_snapshot
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.create_snapshot

    render :json => result.extract
  end

  # Enumerate all snapshots of the given instance
  #
  def enum_snapshots
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.enum_snapshots

    render :json => result.extract
  end

  # Get snapshot detail information
  #
  def snapshot_details
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.snapshot_details params['sid']

    render :json => result.extract
  end

  # Rollback to a snapshot
  #
  def rollback_snapshot
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.rollback_snapshot params['sid']

    render :json => result.extract
  end

  # Delete a snapshot
  #
  def delete_snapshot
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.delete_snapshot params['sid']

    render :json => result.extract
  end

  # Create serialized url for service snapshot
  #
  def create_serialized_url
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.create_serialized_url params['sid']

    render :json => result.extract
  end

  # Get the url to download serialized data for an instance
  def serialized_url
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.serialized_url params['sid']

    render :json => result.extract
  end

    # import serialized data to an instance from url
    #
  def import_from_url
    req = VCAP::Services::Api::SerializedURL.decode(request_body)

    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.import_from_url req

    render :json => result.extract
  end

  # register serialization_data_server
  #
  def register_sds
    req = VCAP::Services::Api::ServiceRegisterSdsRequest.decode(request_body)
    CloudController.logger.debug("Register SDS request: #{req.extract.inspect}")

    success = nil
    sds = SerializationDataServer.find_by_host(req.host)
    if sds
      sds.update_attributes!(req.extract)
    else
      sds = SerializationDataServer.new(req.extract)
      sds.save!
    end

    render :json => {}
  end

  # import serialized data to an instance from uploaded file
  #
  def import_from_data
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    data_file = get_uploaded_data_file
    max_upload_size = AppConfig[:service_lifecycle][:max_upload_size] || 1
    max_upload_size = max_upload_size * 1024 * 1024
    unless data_file && data_file.path && File.exist?(data_file.path) && File.size(data_file.path) < max_upload_size
      if data_file && data_file.path && File.exist?(data_file.path)
        CloudController.logger.debug("import_from_data - Bad request: uploaded file #{data_file.path} (#{File.size(data_file.path)}) exceeeded the size limitation #{max_upload_size}B")
      else
        CloudController.logger.debug("import_from_data - Bad request: uploaded file is not found")
      end
      raise CloudError.new(CloudError::BAD_REQUEST)
    end

    # Select the active serialization_data_servers, the staled sds (no heartbeat in 120 seconds) should be excludedsive
    active_sds = SerializationDataServer.active_sds(120)

    # Currently, we just use Array.sample method to select one of sds randomly
    # In the future, sds could provide info like capability/load/score/priority to help load-balance.
    target_sds ||= (active_sds.sample if active_sds && active_sds.count > 0)
    raise CloudError.new(CloudError::SDS_NOT_FOUND) unless target_sds

    upload_url ="http://#{target_sds.host}:#{target_sds.port}"
    upload_token = target_sds.token
    raise CloudError.new(CloudError::SDS_ERROR, "No upload token provided by registered serialization data server #{target_sds.host}") unless upload_token

    req = {:upload_url => upload_url, :upload_token => upload_token, :data_file_path => data_file.path}
    CloudController.logger.debug("import_from_data - request is #{req.inspect}")

    serialized_url= cfg.import_from_data req
    raise CloudError.new(CloudError::SDS_ERROR, "Serialization returned invalid response.") unless serialized_url.is_a? VCAP::Services::Api::SerializedURL

    result = cfg.import_from_url(serialized_url)
    render :json => result.extract
  ensure
    FileUtils.rm_rf(data_file.path) if data_file && data_file.path && File.exist?(data_file.path)
  end

  # Get job information
  #
  def job_info
    cfg = ServiceConfig.find_by_user_id_and_name(user.id, params['id'])
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    result = cfg.job_info params['job_id']

    render :json => result.extract
  end

  # Binds a provisioned instance to an app
  #
  def bind
    req = VCAP::Services::Api::CloudControllerBindRequest.decode(request_body)

    app = ::App.find_by_collaborator_and_id(user, req.app_id)
    raise CloudError.new(CloudError::APP_NOT_FOUND) unless app

    cfg = ServiceConfig.find_by_name(req.service_id)
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg
    raise CloudError.new(CloudError::FORBIDDEN) unless cfg.provisioned_by?(user)

    binding = app.bind_to_config(cfg)

    resp = {
      :binding_token => binding.binding_token.uuid,
      :label => cfg.service.label
    }
    render :json => resp
  end

  # Binds an app to a service using an existing binding token
  #
  def bind_external
    cli_req = VCAP::Services::Api::BindExternalRequest.decode(request_body)

    app = ::App.find_by_collaborator_and_id(user, cli_req.app_id)
    raise CloudError.new(CloudError::APP_NOT_FOUND) unless app

    tok = ::BindingToken.find_by_uuid(cli_req.binding_token)
    raise CloudError.new(CloudError::TOKEN_NOT_FOUND) unless tok

    cfg = tok.service_config
    raise CloudError.new(CloudError::SERVICE_NOT_FOUND) unless cfg

    app.bind_to_config(cfg, tok.binding_options)

    render :json => {}
  end

  # Unbinds a previously bound instance from an app
  #
  def unbind
    tok = ::BindingToken.find_by_uuid(params['binding_token'])
    raise CloudError.new(CloudError::BINDING_NOT_FOUND) unless tok

    # It's possible that a previous attempt at binding failed, leaving a dangling token.
    # In this case just log the issue and clean up.

    binding = ServiceBinding.find_by_binding_token_id(tok.id)
    unless binding
      CloudController.logger.info("Removing dangling token #{tok.uuid}")
      CloudController.logger.info(tok.inspect)
      tok.destroy
      render :json => {}
      return
    end

    app = binding.app
    svc_config = binding.service_config
    app.unbind_from_config(svc_config)

    render :json => {}
  end

  protected

  # get uploaded serialized data file
  def get_uploaded_data_file
    file = nil
    CloudController.logger.debug("get_uploaded_data_file #{params.inspect}")
    if CloudController.use_nginx
      path = params[:data_file_path]
      wrapper_class = Class.new do
        attr_accessor :path
      end
      file = wrapper_class.new
      file.path = path
    else
      file = params[:data_file]
    end
    file
  end

  def require_service_auth_token
    hdr = VCAP::Services::Api::GATEWAY_TOKEN_HEADER.upcase.gsub(/-/, '_')
    @service_auth_token = request.headers[hdr]
    raise CloudError.new(CloudError::FORBIDDEN) unless @service_auth_token
  end

  def require_sds_auth_token
    hdr = VCAP::Services::Api::SDS_UPLOAD_TOKEN_HEADER.upcase.gsub(/-/, '_')
    @sds_upload_token = request.headers[hdr]
    raise CloudError.new(CloudError::FORBIDDEN) unless @sds_upload_token && @sds_upload_token == AppConfig[:service_lifecycle][:upload_token]
  end

  def require_lifecycle_extension
    raise CloudError.new(CloudError::EXTENSION_NOT_IMPL, "lifecycle") unless AppConfig.has_key?(:service_lifecycle)
  end

  def unify_provider
    # We do not explicitly store the value "core" in the CCDB provider column.
    # Instead, provider = nil represents core, and we treat nil and core interchangeably.
    params[:provider] = nil if params[:provider] == "core"
  end
end
