require 'spec_helper'

describe "bulk_api" do

  shared_examples_for "any request to the bulk api" do
    before :all do
      build_admin_and_user
      make_a_bunch_of_apps
      @bulk_user = AppConfig[:bulk_api][:auth][:user]
      @bulk_password = AppConfig[:bulk_api][:auth][:password]

      @auth_header =  {"HTTP_AUTHORIZATION" =>  ActionController::HttpAuthentication::Basic.encode_credentials(@bulk_user, @bulk_password) }
    end

    after :all do
      App.delete_all
      User.delete_all
    end

    describe "credential discovery" do
      it 'should see credentials in AppConfig' do
        @bulk_password.should_not be_nil
        @bulk_password.size.should > 20
      end

      pending 'should be able to discover credentials through NATS' do
        #TODO: this stuff should be moved to functional tests, when the NATS is up
        EM.run do
          EM.add_timer(5) do
            EM.stop
            fail 'failed to complete within the timeout'
          end

          NATS.request('cloudcontroller.bulk.credentials') do |response|
            @password = response
            EM.stop
          end
        end
      end
    end

    describe 'bulk#apps' do
      it 'requires authentication' do
        get bulk_apps_url
        response.status.should == 401
      end

      it "accepts request without token" do
        #this is a helper method that include authorization header
        get_apps
        response.status.should == 200
      end

      it "returns bulk_token with the intial request" do
        get_apps
        token.should_not be_nil
      end

      it "returns results in the response.body" do
        get_apps
        results.should_not be_nil
      end

      it "returns results that are valid json" do
        get_apps
        results.each { |res|
          res.should be_a_kind_of Array
          res.size.should == 2
          res.last.should be_a_kind_of Hash
          res.last["id"].should_not be_nil
          res.last["framework"].should == 'sinatra'
        }
      end

      it "respects the batch_size parameter" do
        [3,5].each { |size|
          get_apps :batch_size=>size
          results.size.should == size
        }
      end

      it "returns non-intersecting results when token is supplied" do
        size = 2
        get_apps :batch_size => size
        saved_results = results
        saved_results.size.should == size

        get_apps({:bulk_token => token, :batch_size=>size})
        results.size.should == size
        saved_results.each {|saved_result| results.should_not include(saved_result) }
      end

      it "should eventually return entire collection, batch after batch" do
        args = {:batch_size => 2}
        apps = {}

        total_size = App.count

        while apps.size < total_size do
          get_apps(args)
          apps.merge! results
          args[:bulk_token] = token
        end

        apps.size.should == total_size
        get_apps(args)
        results.size.should == 0
      end
    end
  end

  context "using conventional tokens" do
    it_should_behave_like "any request to the bulk api"
  end

  context "using jwt tokens" do
    before :all do
      CloudSpecHelpers.use_jwt_token = true
    end

    it_should_behave_like "any request to the bulk api"
  end

  context "using jwt tokens with RSA keys" do
    before :all do
      CloudSpecHelpers.use_jwt_token_with_rsa_key = true
    end

    it_should_behave_like "any request to the bulk api"
  end


  def get_users(args=nil)
    get(bulk_users_url, args, @auth_header)
  end

  def get_apps(args=nil)
    get(bulk_apps_url, args, @auth_header)
  end

  def token
    body['bulk_token']
  end

  def results
    body['results']
  end

  def body
    Yajl::Parser.parse(response.body)
  end

  def make_a_bunch_of_apps(n=10)
    n.times do
      data = { 'name' => random_name, 'staging' => {'model' => 'sinatra', 'stack' => 'ruby18' }}
      lambda do
        post app_create_path, nil, headers_for(@user.email, nil, data)
        response.should redirect_to(app_get_url(data['name']))
      end.should change(App, :count).by(1)
    end
  end
end
