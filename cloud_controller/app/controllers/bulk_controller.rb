class BulkController < ApplicationController
  skip_before_filter :fetch_user_from_token
  before_filter :authenticate_bulk_api

  # the password is randomly generated at startup and is
  # discoverable through NATS.request('cloudcontroller.bulk.credentials')

  DEFAULT_BATCH_SIZE = 200

  def apps
    render_results_and_token_for_apps
  end

  def counts
    # no Kernel.const_get() for me, thank you.
    model_hash = {
      'app' => App,
      'user' => User
    }

    model_name = params['model'] || 'user'
    if model_hash.keys.include?(model_name)
      model = model_hash[model_name]
      render :json => { :counts => { model_name => model.count }}
    else
      CloudController.logger.error("bulk: counts: invalid model request: #{model_name}")
    end
  end

  private
  def authenticate_bulk_api
    authenticate_or_request_with_http_basic do |user, pass|
      if user==AppConfig[:bulk_api][:auth][:user] &&
          pass==AppConfig[:bulk_api][:auth][:password]
        true
      else
        CloudController.logger.error("bulk: auth failed (user=#{user}, pass=#{pass} from #{request.remote_ip}", :tags => [:auth_failure, :bulk_api])
        false
      end
    end
  end

  def render_results_and_token_for_apps
    results = retrieve_results
    update_token(results)
    render :json => { :results => hash_apps_by_id(results), :bulk_token => bulk_token }
  end

  def retrieve_results
    CloudController.logger.debug("Params: #{params}")
    CloudController.logger.debug("Retrieving bulk results for bulk_token: #{bulk_token}")
    CloudController.logger.debug("WHERE-clause: #{where_clause}")
    App.where(where_clause).order('id').limit(batch_size).to_a
  end

  def hash_apps_by_id(arr)
    arr.inject({}) { |h, app| h[app.id] = hashify_app(app); h }
  end

  def hashify_app(app)
    h = {}
    [:id, :name, :instances, :state, :framework, :runtime, :memory, :package_state, :updated_at
    ].each {|field| h[field] = app.send(field) }

    h[:version] = app.generate_version
    h
  end

  def update_token(results)
    @bulk_token = results.empty? ? {} : {:id => results.last.id}
  end

  def where_clause
    @where_clause ||= bulk_token.to_a.map { |k,v| "#{sanitize_atom(k)} > #{sanitize_atom(v)}" }.join(" AND ")
  end

  def sanitize_atom(atom)
    atom = atom.to_s
    unless atom =~ /^[a-zA-Z0-9_]+$/
      CloudController.logger.error("invalid atom #{atom} in bulk_token #{bulk_token}")
      raise CloudError.new(CloudError::BAD_REQUEST, "bad atom #{atom} in bulk_api token")
    end
    atom
  end

  def batch_size
    @batch_size||=params['batch_size'] ? json_param('batch_size').to_i : DEFAULT_BATCH_SIZE
  end

  def bulk_token
    @bulk_token||=params['bulk_token'] ? params['bulk_token'] : {}
    @bulk_token = Yajl::Parser.parse(@bulk_token) if @bulk_token.kind_of? String
    @bulk_token
  end
end
