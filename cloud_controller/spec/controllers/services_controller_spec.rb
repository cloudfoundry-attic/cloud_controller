require 'spec_helper'
require 'support/service_controller_helper'

require 'thin'
require 'uri'

describe ServicesController do

  describe "Gateway facing apis" do
    before :each do
      request.env['CONTENT_TYPE'] = Mime::JSON
      request.env['HTTP_ACCEPT'] = Mime::JSON
      request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'foobar'
    end

    describe '#create' do

      it 'should reject requests without auth tokens' do
        request.env.delete 'HTTP_X_VCAP_SERVICE_TOKEN'
        post :create
        response.status.should == 403
      end

      it 'should should reject posts with malformed bodies' do
        request.env['RAW_POST_DATA'] = 'foobar'
        post :create
        response.status.should == 400
      end

      it 'should reject requests with missing parameters' do
        request.env['RAW_POST_DATA'] = '{}'
        post :create
        response.status.should == 400
      end

      it 'should reject requests with invalid parameters' do
        request.env['RAW_POST_DATA'] = {:label => 'foobar', :url => 'zazzle'}.to_json
        post :create
        response.status.should == 400
      end

      it 'should create service offerings for builtin services' do
        AppConfig[:builtin_services][:foo] = {:token => 'foobar'}
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://www.google.com')
        end
        AppConfig[:builtin_services].delete(:foo)
        response.status.should == 200
      end

      it 'should create service offerings for single proxied service' do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'broker'
        AppConfig[:service_proxy] = {:token => ['broker']}
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://localhost:56789')
        end
        response.status.should == 200
      end

      it 'should create service offerings for multiple proxied service' do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'broker'
        AppConfig[:service_proxy] = {:token => ['broker', 'foobar']}
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://localhost:56789')
        end
        response.status.should == 200
      end

      it 'should not create brokered service offerings if token mismatch' do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'foobar'
        AppConfig[:service_proxy] = {:token => ['broker']}
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://localhost:56789')
        end
        response.status.should == 403
      end

      it 'should not create service offerings if not builtin' do
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :url => 'http://www.google.com',
            :supported_versions => [],
            :version_aliases => {},
            :plans => ['foo'])
        end
        response.status.should == 403
      end

      it 'should update existing offerings' do
        acls = {
          'wildcards' => ['*@foo.com'],
          'plans' => {'free' => {'users' => ['a@b.com']}}
        }
        svc = Service.create(
          :label => 'foo-bar',
          :url   => 'http://www.google.com',
          :token => 'foobar',
          :plans => ['foo'])
        svc.should be_valid

        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :url   => 'http://www.google.com',
            :supported_versions => [],
            :version_aliases => {},
            :acls  => acls,
            :plans => ['foo'],
            :timeout => 20,
            :description => 'foobar')
        end
        response.status.should == 200
        svc = Service.find_by_label('foo-bar')
        svc.should_not be_nil
        svc.description.should == 'foobar'
        svc.timeout.should == 20
      end


      it 'should support reverting existing offerings to nil' do
        acls = {
          'wildcards' => ['*@foo.com'],
          'plans' => {'free' => {'users' => ['aaa@bbb.com']}}
        }
        svc = Service.create(
          :label => 'foo-bar',
          :url   => 'http://www.google.com',
          :token => 'foobar',
          :acls  => acls,
          :timeout => 20,
          :plans => ['foo'])
        svc.should be_valid

        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :url   => 'http://www.google.com',
            :supported_versions => [],
            :version_aliases => {},
            :plans => ['foo'],
            :description => 'foobar')
        end
        response.status.should == 200
        svc = Service.find_by_label('foo-bar')
        svc.should_not be_nil
        svc.timeout.should be_nil
        svc.acls.should be_nil
      end

      it 'should return not authorized on token mismatch for non builtin services' do
        svc = Service.create(
          :label => 'foo-bar',
          :url   => 'http://www.google.com',
          :token => ['foobar'])
        svc.should be_valid

        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'barfoo'
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :plans => ['foo'],
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://www.google.com')
        end
        response.status.should == 403
      end

      it 'should return not authorized on token mismatch for builtin services' do
        AppConfig[:builtin_services][:foo] = {:token => 'foobar'}
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :url   => 'http://www.google.com')
        end
        response.status.should == 200
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'barfoo'
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'foo-bar',
            :supported_versions => [],
            :version_aliases => {},
            :plans => ['foo'],
            :url   => 'http://www.google.com')
        end
        response.status.should == 403
        AppConfig[:builtin_services].delete(:foo)
      end

      it 'should ensure that builtin services have nil or core provider' do
        AppConfig[:builtin_services][:foo1] = {:token => 'foobar1'}
        AppConfig[:builtin_services][:foo2] = {:token => 'foobar2'}

        svc_nil_provider = Service.create(
          :label => 'foo1-1',
          :url   => 'http://www.fooservice.com',
          :token => ['foobar1'])
        svc_nil_provider.should be_valid
        svc_nil_provider.is_builtin?.should == true

        svc_core_provider = Service.create(
          :label => 'foo2-1',
          :url   => 'http://www.foo2service.com',
          :token => ['foobar2'],
          :provider => "core")
        svc_core_provider.should be_valid
        svc_core_provider.is_builtin?.should == true

        svc_my_provider = Service.create(
          :label => 'foo1-1',
          :url   => 'http://www.barservice.com',
          :token => ['bar'],
          :provider => "my")
        svc_my_provider.should be_valid
        svc_my_provider.is_builtin?.should == false

        AppConfig[:builtin_services].delete(:foo1)
        AppConfig[:builtin_services].delete(:foo2)
      end

    end

    describe '#delete' do
      before :each do
        @svc1 = Service.create(
          :label => 'foo-bar',
          :url   => 'http://www.google.com',
          :token => 'foobar')
        @svc2 = Service.create(
          :label => 'foo-bar',
          :provider => 'test',
          :url   => 'http://www.google.com',
          :token => 'foobar')
        @svc1.should be_valid
        @svc2.should be_valid
      end

      it 'should return not found for unknown label services' do
        delete :delete, :label => 'xxx'
        response.status.should == 404
      end

      it 'should return not found for unknown provider services' do
        delete :delete, :label => 'foo-bar', :provider => 'xxx'
        response.status.should == 404
      end

      it 'should return not authorized on token mismatch' do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'barfoo'
        delete :delete, :label => 'foo-bar'
        response.status.should == 403
      end

      it 'should delete existing offerings which has null provider' do
        delete :delete, :label => 'foo-bar'
        response.status.should == 200

        svc = Service.find_by_label_and_provider('foo-bar', nil)
        svc.should be_nil
      end

      it 'should delete existing offerings which has specific provider' do
        delete :delete, :label => 'foo-bar', :provider => 'test'
        response.status.should == 200

        svc = Service.find_by_label_and_provider('foo-bar', 'test')
        svc.should be_nil
      end
    end

    describe '#get' do
      before :each do
        @svc1 = Service.create(
          :label => 'foo-bar',
          :url   => 'http://www.google.com',
          :plans => ['free', 'nonfree'],
          :token => 'foobar')
        @svc2 = Service.create(
          :label => 'foo-bar',
          :provider => 'test',
          :url   => 'http://www.google.com',
          :plans => ['free', 'nonfree'],
          :token => 'foobar')
        @svc1.should be_valid
        @svc2.should be_valid
      end

      it 'should return not found for unknown label services' do
        get :get, :label => 'xxx'
        response.status.should == 404
      end

      it 'should return not found for unknown provider services' do
        get :get, :label => 'foo-bar', :provider => 'xxx'
        response.status.should == 404
      end

      it 'should return not authorized on token mismatch' do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'xxx'
        get :get, :label => 'foo-bar'
        response.status.should == 403
      end

      it 'should return the specific service offering which has null provider' do
        get :get, :label => 'foo-bar'
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["label"].should == 'foo-bar'
        resp["url"].should   == 'http://www.google.com'
        resp["plans"].should == ['free', 'nonfree']
        resp["provider"].should == nil
      end

      it 'should return the specific service offering which has specific provider' do
        get :get, :label => 'foo-bar', :provider => 'test'
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["label"].should == 'foo-bar'
        resp["url"].should   == 'http://www.google.com'
        resp["plans"].should == ['free', 'nonfree']
        resp["provider"].should == 'test'
      end
    end

    describe '#list_handles' do
      it 'should return not found for unknown services' do
        get :list_handles, :label => 'foo-bar'
        response.status.should == 404
      end

      it 'should return provisioned and bound handles' do
        svc1 = Service.new
        svc1.label = "foo-bar"
        svc1.url   = "http://localhost:56789"
        svc1.token = 'foobar'
        svc1.save
        svc1.should be_valid

        svc2 = Service.new
        svc2.label    = "foo-bar"
        svc2.provider = "test"
        svc2.url      = "http://localhost:56789"
        svc2.token    = 'foobar'
        svc2.save
        svc2.should be_valid

        cfg1 = ServiceConfig.new(:name => 'foo1', :alias => 'bar1', :service => svc1)
        cfg1.save
        cfg1.should be_valid

        cfg2 = ServiceConfig.new(:name => 'foo2', :alias => 'bar2', :service => svc2)
        cfg2.save
        cfg2.should be_valid

        bdg1 = ServiceBinding.new(
          :name  => 'bind1',
          :service_config  => cfg1,
          :configuration   => {},
          :credentials     => {},
          :binding_options => []
        )
        bdg1.save
        bdg1.should be_valid

        bdg2 = ServiceBinding.new(
          :name  => 'bind2',
          :service_config  => cfg2,
          :configuration   => {},
          :credentials     => {},
          :binding_options => []
        )
        bdg2.save
        bdg2.should be_valid

        get :list_handles, :label => 'foo-bar'
        response.status.should == 200
        handles = JSON.parse(response.body)["handles"]
        handles.size.should == 2
        handles[0]["service_id"].should == "foo1"
        handles[1]["service_id"].should == "bind1"
        get :list_handles, :label => 'foo-bar', :provider => "test"
        response.status.should == 200
        handles = JSON.parse(response.body)["handles"]
        handles.size.should == 2
        handles[0]["service_id"].should == "foo2"
        handles[1]["service_id"].should == "bind2"
      end
    end

    describe '#list_proxied_services' do
      before :each do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'broker'
        AppConfig[:service_proxy] = {:token => ['broker']}
      end

      it "should return not authorized on token mismatch" do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'foobar'
        get :list_proxied_services
        response.status.should == 403
      end

      it "should not list builtin services" do
        AppConfig[:builtin_services] = {
          :foo => {:token => ["foobar"]}
        }
        svc = Service.new
        svc.label = "foo-1.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'foobar'
        svc.save
        svc.should be_valid

        get :list_proxied_services
        response.status.should == 200
        Yajl::Parser.parse(response.body)['proxied_services'].should be_empty
      end

      it "should list single brokered services" do
        AppConfig[:builtin_services] = {
          :foo => {:token => ["foobar"]}
        }

        svc = Service.new
        svc.label = "brokered-1.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'broker'
        svc.save
        svc.should be_valid

        get :list_proxied_services
        response.status.should == 200
        Yajl::Parser.parse(response.body)['proxied_services'].size.should == 1
      end

      it "should list multiple brokered services" do
        AppConfig[:builtin_services] = {
          :foo => {:token => ["foobar"]}
        }

        svc = Service.new
        svc.label = "brokered-1.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'broker'
        svc.save
        svc.should be_valid

        svc = Service.new
        svc.label = "brokered-2.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'broker'
        svc.save
        svc.should be_valid

        get :list_proxied_services
        response.status.should == 200
        Yajl::Parser.parse(response.body)['proxied_services'].size.should == 2
      end

      it "should list multiple brokered services with different keys" do
        AppConfig[:service_proxy] = {
          :token => ['broker', 'foobar']
        }

        svc = Service.new
        svc.label = "brokered-1.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'broker'
        svc.save
        svc.should be_valid

        svc = Service.new
        svc.label = "brokered-2.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'foobar'
        svc.save
        svc.should be_valid

        svc = Service.new
        svc.label = "brokered-3.0"
        svc.url   = "http://localhost:56789"
        svc.token = 'broker'
        svc.save
        svc.should be_valid

        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'broker'
        get :list_proxied_services
        response.status.should == 200
        Yajl::Parser.parse(response.body)['proxied_services'].size.should == 2

        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'foobar'
        get :list_proxied_services
        response.status.should == 200
        Yajl::Parser.parse(response.body)['proxied_services'].size.should == 1
      end

      it "should return all non-null and mandatory fields for the service" do
        AppConfig[:builtin_services] = {
          :foo => {:token => ["foobar"]}
        }
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'broker'
        post_msg :create do
          VCAP::Services::Api::ServiceOfferingRequest.new(
            :label => 'brokered-1.0',
            :url   => 'http://localhost:56789',
            :supported_versions => ["1.0" ],
            :version_aliases => { "current" => "1.0" },
            :provider => 'fooprovider',
          )
        end
        response.status.should == 200

        get :list_proxied_services
        response.status.should == 200
        services = Yajl::Parser.parse(response.body)['proxied_services']
        services.size.should == 1

        keys = %w(label url provider active supported_versions version_aliases)
        keys.each { |k|
          services[0].keys.include?(k).should == true
        }

        services[0]["label"].should == "brokered-1.0"
        services[0]["provider"].should == "fooprovider"
        services[0]["active"].should be_true
        services[0]["url"].should == "http://localhost:56789"
        services[0]["supported_versions"].size.should == 1
        services[0]["supported_versions"][0].should == "1.0"
        services[0]["version_aliases"]["current"].should == "1.0"
      end
    end

    describe '#update_handle' do
      before :each do
        request.env['HTTP_X_VCAP_SERVICE_TOKEN'] = 'foobar'
        AppConfig[:builtin_services] = {
          :foo1 => {:token=>"foobar"},
          :foo2 => {:token=>"foobar"}
        }

        svc1 = Service.new
        svc1.label = "foo-bar"
        svc1.url   = "http://localhost:56789"
        svc1.token = 'foobar'
        svc1.save
        svc1.should be_valid
        @svc1 = svc1

        cfg1 = ServiceConfig.new(:name => 'foo1', :alias => 'bar1', :service => svc1)
        cfg1.save
        cfg1.should be_valid
        @cfg1 = cfg1

        bdg1 = ServiceBinding.new(
          :name  => 'bind1',
          :service_config  => cfg1,
          :configuration   => {},
          :credentials     => {},
          :binding_options => []
        )
        bdg1.save
        bdg1.should be_valid
        @bdg1 = bdg1

        svc2 = Service.new
        svc2.label    = "foo-bar"
        svc2.provider = "test"
        svc2.url      = "http://localhost:56789"
        svc2.token    = 'foobar'
        svc2.save
        svc2.should be_valid
        @svc2 = svc2

        cfg2 = ServiceConfig.new(:name => 'foo2', :alias => 'bar2', :service => svc2)
        cfg2.save
        cfg2.should be_valid
        @cfg2 = cfg2

        bdg2 = ServiceBinding.new(
          :name  => 'bind2',
          :service_config  => cfg2,
          :configuration   => {},
          :credentials     => {},
          :binding_options => []
        )
        bdg2.save
        bdg2.should be_valid
        @bdg2 = bdg2
      end

      it 'should return not found for unknown handles' do
        post_msg :update_handle, :label => @svc1.label, :id => 'xxx' do
          VCAP::Services::Api::HandleUpdateRequest.new(
             :service_id => 'xxx',
             :configuration => [],
             :credentials   => []
          )
        end
        response.status.should == 404
      end

      it 'should update provisioned handles that the service has null provider' do
        post_msg :update_handle, :label => @svc1.label, :id => @cfg1.name do
          VCAP::Services::Api::HandleUpdateRequest.new(
             :service_id => @cfg1.name,
             :configuration => [],
             :credentials   => []
          )
        end
        response.status.should == 200
      end

      it 'should update provisioned handles that the service has specific provider' do
        post_msg :update_handle, :label => @svc2.label, :provider => @svc2.provider, :id => @cfg2.name do
          VCAP::Services::Api::HandleUpdateRequest.new(
             :service_id => @cfg2.name,
             :configuration => [],
             :credentials   => []
          )
        end
        response.status.should == 200
      end

      it 'should update bound handles that the service has null provider' do
        post_msg :update_handle, :label => @svc1.label, :id => @bdg1.name do
          VCAP::Services::Api::HandleUpdateRequest.new(
             :service_id => @bdg1.name,
             :configuration => ['foo'],
             :credentials   => ['bar']
          )
        end
        foo = ServiceBinding.find_by_name(@bdg1.name)
        response.status.should == 200
      end

      it 'should update bound handles that the service has specific provider' do
        post_msg :update_handle, :label => @svc2.label, :provider => @svc2.provider, :id => @bdg2.name do
          VCAP::Services::Api::HandleUpdateRequest.new(
             :service_id => @bdg2.name,
             :configuration => ['foo'],
             :credentials   => ['bar']
          )
        end
        foo = ServiceBinding.find_by_name(@bdg2.name)
        response.status.should == 200
      end
    end
  end

  describe "User facing apis" do
    before :each do
      u = User.new(:email => 'foo@bar.com')
      u.set_and_encrypt_password('foobar')
      u.save
      u.should be_valid
      @user = u

      a = App.new(
        :owner => u,
        :name => 'foobar',
        :framework => 'sinatra',
        :runtime => 'ruby18')
      a.save
      a.should be_valid
      @app = a

      svc = Service.new
      svc.label = "foo-bar"
      svc.url   = "http://localhost:56789"
      svc.token = 'foobar'
      svc.plans = ['free', 'nonfree']
      svc.supported_versions = ["bar", "baz"]
      svc.version_aliases = {"current" => "bar"}
      svc.save
      svc.should be_valid
      @svc = svc

      svc_test = Service.new
      svc_test.label    = "foo-bar"
      svc_test.provider = "test"
      svc_test.url      = "http://localhost:56789"
      svc_test.token    = 'foobar'
      svc_test.plans    = ['free', 'nonfree']
      svc_test.supported_versions = ["bar", "baz"]
      svc_test.version_aliases = {"current" => "bar"}
      svc_test.save
      svc_test.should be_valid
      @svc_test = svc_test

      request.env['CONTENT_TYPE'] = Mime::JSON
      request.env['HTTP_AUTHORIZATION'] = UserToken.create('foo@bar.com').encode
    end

    describe '#list' do
      it 'should return service offerings' do
        get :list
        response.status.should == 200
        result = JSON.parse(response.body)
        result["generic"]["foo"]["core"]["bar"]["label"].should == "foo-bar"
        result["generic"]["foo"]["core"]["bar"]["url"].should == "http://localhost:56789"
        result["generic"]["foo"]["core"]["bar"]["plans"].should == ["free", "nonfree"]
        result["generic"]["foo"]["core"]["bar"]["active"].should == true
        result["generic"]["foo"]["test"]["bar"]["label"].should == "foo-bar"
        result["generic"]["foo"]["test"]["bar"]["url"].should == "http://localhost:56789"
        result["generic"]["foo"]["test"]["bar"]["plans"].should == ["free", "nonfree"]
        result["generic"]["foo"]["test"]["bar"]["active"].should == true
      end
    end

    describe '#provision' do

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :provision
        response.status.should == 403
      end

      it 'should return not found for unknown services' do
        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'bar-foo',
            :name  => 'foo',
            :version => 'bar',
            :plan  => 'free')
        end
        response.status.should == 404
      end

      it 'should provision services' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)
        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => 'foo',
            :version => 'bar',
            :plan  => 'free')
        end
        response.status.should == 200
        stop_gateway(gw_pid)
      end

      it 'should provision services with specific provider' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)
        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :provider => 'test',
            :version => 'bar',
            :name  => 'foo',
            :plan  => 'free')
        end
        response.status.should == 200
        stop_gateway(gw_pid)
      end

      it 'should fail to provision a config with the same name as an existing config' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => 'foo',
            :version => 'bar',
            :plan  => 'free')
        end
        response.status.should == 200

        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => 'foo',
            :version => 'bar',
            :plan  => 'free')
        end
        response.status.should == 400

        stop_gateway(gw_pid)
      end

      it "should support default service version" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).with('bar', 'free').returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => "foo",
            :version => 'bar',
            :plan  => 'free'
          )
        end
        response.status.should == 200

        stop_gateway(gw_pid)
      end

      it "should support version in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        %w(bar baz).each do |version|
          post_msg :provision do
            VCAP::Services::Api::CloudControllerProvisionRequest.new(
              :label => 'foo-bar',
              :name  => "foo-#{version}",
              :plan  => 'free',
              :version => version
            )
          end
          response.status.should == 200
        end

        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => 'foo-qux',
            :plan  => 'free',
            :version => 'qux'
          )
        end
        response.status.should == 404
        response.body.should =~ /Unsupported service version qux/

        stop_gateway(gw_pid)
      end

      it "should support version alias in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          VCAP::Services::Api::CloudControllerProvisionRequest.new(
            :label => 'foo-bar',
            :name  => 'foo-current',
            :plan  => 'free',
            :version => 'current'
          )
        end
        response.status.should == 200

        stop_gateway(gw_pid)
      end
    end

    describe "#bind" do
      before :each do
        cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :bind
        response.status.should == 403
      end

      it 'should return not found for unknown apps' do
        post_msg :bind do
          VCAP::Services::Api::CloudControllerBindRequest.new(
            :app_id          => 1234,
            :service_id      => 'xxx',
            :binding_options => []
          )
        end
        response.status.should == 404
      end

      it 'should return not found for unknown service configs' do
        post_msg :bind do
          VCAP::Services::Api::CloudControllerBindRequest.new(
            :app_id          => @app.id,
            :service_id      => 'xxx',
            :binding_options => []
          )
        end
        response.status.should == 404
      end

      it 'should successfully bind a known config to a known app' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:bind_instance).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)
        post_msg :bind do
          VCAP::Services::Api::CloudControllerBindRequest.new(
            :service_id      => @cfg.name,
            :app_id          => @app.id,
            :binding_options => ['foo']
          )
        end
        response.status.should == 200
        binding = ServiceBinding.find_by_user_id_and_app_id(@user.id, @app.id)
        binding.should_not be_nil
        stop_gateway(gw_pid)
      end
    end

    describe "#bind_external" do
      before :each do
        cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg

        tok = BindingToken.generate(:label => 'foo', :service_config => cfg, :binding_options => ['free'])
        tok.save
        tok.should be_valid
        @tok = tok
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :bind_external
        response.status.should == 403
      end

      it 'should return not found for unknown tokens' do
        post_msg :bind_external do
          VCAP::Services::Api::BindExternalRequest.new(
            :app_id        => @app.id,
            :binding_token => 'xxx'
          )
        end
        response.status.should == 404
      end

      it 'should return not found for unknown apps' do
        post_msg :bind_external do
          VCAP::Services::Api::BindExternalRequest.new(
            :app_id        => 1234,
            :binding_token => @tok.uuid
          )
        end
        response.status.should == 404
      end

      it 'should successfully bind a known token to a known app' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:bind_instance).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)
        post_msg :bind_external do
          VCAP::Services::Api::BindExternalRequest.new(
            :app_id        => @app.id,
            :binding_token => @tok.uuid
          )
        end
        response.status.should == 200
        binding = ServiceBinding.find_by_user_id_and_app_id(@user.id, @app.id)
        binding.should_not be_nil
        stop_gateway(gw_pid)
      end
    end

    describe "#unbind" do
      before :each do
        cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg

        tok = BindingToken.generate(
          :label => 'foo-bar',
          :binding_options => [],
          :service_config => @cfg
        )
        tok.save
        tok.should be_valid
        @tok = tok

        bdg = ServiceBinding.new(
          :app   => @app,
          :user  => @user,
          :name  => 'xxxxx',
          :service_config  => @cfg,
          :configuration   => {},
          :credentials     => {},
          :binding_options => [],
          :binding_token   => @tok
        )
        bdg.save
        bdg.should be_valid
        @bdg = bdg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        delete :unbind, :binding_token => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown bindings' do
        delete :unbind, :binding_token => 'xxx'
        response.status.should == 404
      end

      it 'should successfully delete known bindings' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:unbind_instance).returns(true)
        gw_pid = start_gateway(@svc, shim)
        delete :unbind, :binding_token => @bdg.binding_token.uuid
        response.status.should == 200
        binding = ServiceBinding.find_by_user_id_and_app_id(@user.id, @app.id)
        binding.should be_nil
        stop_gateway(gw_pid)
      end
    end


    describe '#unprovision' do
      before :each do
        cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg

        bdg = ServiceBinding.new(
          :app   => @app,
          :user  => @user,
          :name  => 'xxx',
          :service_config => @cfg,
          :credentials => {},
          :binding_options => []
        )
        bdg.save
        bdg.should be_valid
        @bdg = bdg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        delete :unprovision, :id => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        delete :unprovision, :id => 'xxx'
        response.status.should == 404
      end

      it 'should successfully delete known service configs and their associated bindings' do
        shim = ServiceProvisionerStub.new
        shim.stubs(:unprovision_service).returns(true)
        gw_pid = start_gateway(@svc, shim)
        delete :unprovision, :id => @cfg.alias
        response.status.should == 200
        binding = ServiceBinding.find_by_user_id_and_app_id(@user.id, @app.id)
        binding.should be_nil
        cfg = ServiceConfig.find_by_id(@cfg.id)
        cfg.should be_nil
        stop_gateway(gw_pid)
      end
    end

    describe "#lifecycle_extension" do

      it 'should return not implemented error when lifecycle is disabled' do
        begin
          origin = AppConfig.delete :service_lifecycle
          %w(create_snapshot enum_snapshots import_from_url import_from_data).each do |api|
            post api.to_sym, :id => 'xxx'
            response.status.should == 501
            resp = Yajl::Parser.parse(response.body)
            resp['description'].include?("not implemented").should == true
          end

          %w(snapshot_details update_snapshot_name rollback_snapshot delete_snapshot serialized_url create_serialized_url ).each do |api|
            post api.to_sym, :id => 'xxx', :sid => '1'
            response.status.should == 501
            resp = Yajl::Parser.parse(response.body)
            resp['description'].include?("not implemented").should == true
          end

          get :job_info, :id => 'xxx', :job_id => '1'
          response.status.should == 501
          resp = Yajl::Parser.parse(response.body)
          resp['description'].include?("not implemented").should == true

        ensure
          AppConfig[:service_lifecycle] = origin
        end
      end
    end

    describe "#create_snapshot" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :create_snapshot, :id => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        post :create_snapshot, :id => 'xxx'
        response.status.should == 404
      end

      it 'should create a snapshot job' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:create_snapshot).with(:service_id => @cfg.name).returns job

        post :create_snapshot, :id => @cfg.name
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == "abc"
      end

    end

    describe "#enum_snapshots" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        get :enum_snapshots, :id => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        get :enum_snapshots, :id => 'xxx'
        response.status.should == 404
      end

      it 'should enum snapshots' do
        snapshots = VCAP::Services::Api::SnapshotList.decode(
          {
          :snapshots => [{:snapshot_id => "abc"}]
          }.to_json
        )
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:enum_snapshots).with(:service_id => @cfg.name).returns snapshots

        post :enum_snapshots, :id => @cfg.name
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["snapshots"].size.should == 1
        resp["snapshots"][0]["snapshot_id"].should == "abc"
      end
    end

    describe "#snapshot_details" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        get :snapshot_details, :id => 'xxx' , :sid => 'yyy'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        get :snapshot_details, :id => 'xxx', :sid => 'yyy'
        response.status.should == 404
      end

      it 'should get snapshot_details' do
        snapshot = VCAP::Services::Api::Snapshot.decode(
          {
            :snapshot_id => "abc",
            :date => "1",
            :size => 123,
            :name => "foo",
          }.to_json
        )
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:snapshot_details).with(:service_id => @cfg.name, :snapshot_id => snapshot.snapshot_id).returns snapshot

        get :snapshot_details, :id => @cfg.name, :sid => snapshot.snapshot_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["snapshot_id"].should == "abc"
      end

      it "should handle not found error in snapshot details" do
        err = VCAP::Services::Api::ServiceGatewayClient::NotFoundResponse.new(
            VCAP::Services::Api::ServiceErrorResponse.decode(
            {:code => 10000, :description => "not found"}.to_json
          )
        )
        snapshot_id = "abc"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:snapshot_details).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).raises err

        get :snapshot_details, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 404
      end
    end

    describe "#update_snapshot_name" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :update_snapshot_name, :id => 'xxx' , :sid => 'yyy'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        post_msg :update_snapshot_name, :id => 'xxx', :sid => 'yyy' do
          VCAP::Services::Api::UpdateSnapshotNameRequest.new(:name => "new name")
        end
        response.status.should == 404
      end

      it 'should update snapshot name' do
        empty_response = VCAP::Services::Api::EMPTY_REQUEST
        VCAP::Services::Api::ServiceGatewayClient.any_instance.expects(:update_snapshot_name).with(anything).returns empty_response

        post_msg :update_snapshot_name, :id => @cfg.name, :sid => "1" do
          VCAP::Services::Api::UpdateSnapshotNameRequest.new(:name => "new name")
        end
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp.should == {}
      end
    end

    describe "#rollback_snapshot" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        put :rollback_snapshot, :id => 'xxx', :sid => 'yyy'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        put :rollback_snapshot, :id => 'xxx' , :sid => 'yyy'
        response.status.should == 404
      end

      it 'should rollback a snapshot' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        snapshot_id = "abc"

        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:rollback_snapshot).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).returns job

        put :rollback_snapshot, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == "abc"
      end

      it "should handle not found error in rollback snapshot" do
        err = VCAP::Services::Api::ServiceGatewayClient::NotFoundResponse.new(
            VCAP::Services::Api::ServiceErrorResponse.decode(
            {:code => 10000, :description => "not found"}.to_json
          )
        )
        snapshot_id = "abc"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:rollback_snapshot).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).raises err

        put :rollback_snapshot, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 404
      end
    end

    describe "#delete_snapshot" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        delete :delete_snapshot, :id => 'xxx', :sid => 'yyy'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        delete :delete_snapshot, :id => 'xxx' , :sid => 'yyy'
        response.status.should == 404
      end

      it 'should delete a snapshot' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        snapshot_id = "abc"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:delete_snapshot).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).returns job

        delete :delete_snapshot, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == "abc"
      end

      it "should handle not found error in delete snapshot" do
        err = VCAP::Services::Api::ServiceGatewayClient::NotFoundResponse.new(
            VCAP::Services::Api::ServiceErrorResponse.decode(
            {:code => 10000, :description => "not found"}.to_json
          )
        )
        snapshot_id = "abc"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:delete_snapshot).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).raises err

        delete :delete_snapshot, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 404
      end
    end

    describe "#serialized_url" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        get :serialized_url, :id => 'xxx', :sid => '1'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        get :serialized_url, :id => 'xxx', :sid => '1'
        response.status.should == 404
      end

      it 'should get serialized url' do
        url = "http://api.vcap.me"
        snapshot_id = "abc"
        serialized_url = VCAP::Services::Api::SerializedURL.new(:url  => url)
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:serialized_url).with(:service_id => @cfg.name, :snapshot_id => snapshot_id ).returns serialized_url

        get :serialized_url, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["url"].should == url
      end
    end

    describe "#create_serialized_url" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        post :create_serialized_url, :id => 'xxx', :sid => '1'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        post :create_serialized_url, :id => 'xxx', :sid => '1'
        response.status.should == 404
      end

      it 'should create serialized url job' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        snapshot_id = "abc"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:create_serialized_url).with(:service_id => @cfg.name, :snapshot_id => snapshot_id).returns job

        post :create_serialized_url, :id => @cfg.name, :sid => snapshot_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == "abc"
      end
    end

    describe "#import_from_url" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        put :import_from_url, :id => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        put_msg :import_from_url, :id => 'xxx' do
          VCAP::Services::Api::SerializedURL.new(:url  => 'http://api.vcap.me')
        end
        response.status.should == 404
      end

      it 'should return bad request for malformed request' do
        put_msg :import_from_url, :id => 'xxx' do
          # supply wrong request
          VCAP::Services::Api::SerializedData.new(:data => "raw_data")
        end
        response.status.should == 400
      end

      it 'should create import from url job' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        url = "http://api.cloudfoundry.com"

        req = VCAP::Services::Api::SerializedURL.new(:url => url)
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:import_from_url).with(anything).returns job

        put_msg :import_from_url, :id => @cfg.name do
          req
        end
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == "abc"
      end
    end

    describe "#import_from_data" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        put :import_from_data, :id => 'xxx'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        begin
          tmp_file = Tempfile.new('foo_import_from_data')
          put :import_from_data, :id => 'xxx', :data_file => tmp_file
          response.status.should == 404
        ensure
          FileUtils.rm_rf(tmp_file.path) if tmp_file
        end
      end

      it 'should create import from data job' do
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => "abc",
          :status => "queued",
          :start_time => "1"
          }.to_json
        )

        url = "http://api.cloudfoundry"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:import_from_url).with(anything).returns job
        VCAP::Services::Api::SDSClient.any_instance.stubs(:import_from_data).with(anything).returns VCAP::Services::Api::SerializedURL.new(:url => url)
        begin
          tmp_file = Tempfile.new('foo_import_from_data')
          put :import_from_data, :id => @cfg.name, :data_file => tmp_file
          response.status.should == 200
          resp = Yajl::Parser.parse(response.body)
          resp["job_id"].should == "abc"
        ensure
          FileUtils.rm_rf(tmp_file.path) if tmp_file
        end
      end
    end

    describe "#job_info" do
      before :each do
        cfg = ServiceConfig.new(:name => 'lifecycle', :alias => 'bar', :service => @svc, :user => @user)
        cfg.save
        cfg.should be_valid
        @cfg = cfg
      end

      it 'should return not authorized for unknown users' do
        request.env['HTTP_AUTHORIZATION'] = UserToken.create('bar@foo.com').encode
        get :job_info, :id => 'xxx', :job_id => 'yyy'
        response.status.should == 403
      end

      it 'should return not found for unknown ids' do
        get :job_info, :id => 'xxx' , :job_id => 'yyy'
        response.status.should == 404
      end

      it 'should return job_info' do
        job_id = "job1"
        job = VCAP::Services::Api::Job.decode(
          {
          :job_id => job_id,
          :status => "queued",
          :start_time => "1"
          }.to_json
        )
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:job_info).with(:service_id => @cfg.name, :job_id => job_id).returns job

        get :job_info, :id => @cfg.name, :job_id => job_id
        response.status.should == 200
        resp = Yajl::Parser.parse(response.body)
        resp["job_id"].should == job_id
      end

      it "should handle not found error in get job_info" do
        err = VCAP::Services::Api::ServiceGatewayClient::NotFoundResponse.new(
            VCAP::Services::Api::ServiceErrorResponse.decode(
            {:code => 10000, :description => "job not found"}.to_json
          )
        )
        job_id = "job1"
        VCAP::Services::Api::ServiceGatewayClient.any_instance.stubs(:job_info).with(:service_id => @cfg.name, :job_id => job_id).raises err

        get :job_info, :id => @cfg.name, :job_id => job_id
        response.status.should == 404
      end
    end
  end
end
