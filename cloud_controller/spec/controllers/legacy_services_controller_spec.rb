require 'spec_helper'
require 'support/service_controller_helper'

require 'thin'
require 'uri'
require 'json'


describe LegacyServicesController do

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
      svc.label = "foo-1.0"
      svc.provider = nil # the core provider
      svc.url   = "http://localhost:56789"
      svc.token = 'foobar'
      svc.plans = ['free', 'nonfree']
      svc.supported_versions = ["1.0", "2.0"]
      svc.version_aliases = {"current" => "1.0"}
      svc.save
      svc.should be_valid
      @svc = svc


      request.env['CONTENT_TYPE'] = Mime::JSON
      request.env['HTTP_AUTHORIZATION'] = UserToken.create('foo@bar.com').encode

    end

    describe '#provision' do

      it "should support version in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        %w(1.0 2.0).each do |version|
          post_msg :provision do
            LegacyVmcMessages::ProvisionRequest.new(
              :tier => 'free',
              :vendor => 'foo',
              :name  => "foo-#{version}",
              :version => version
            )
          end
          response.status.should == 200
        end

        stop_gateway(gw_pid)
      end

      it "should support version alias in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).with('1.0', 'free').returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => 'foo-current',
            :version => 'current'
          )
        end
        response.status.should == 200
        stop_gateway(gw_pid)
      end

      it "should raise error if version mismatch" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => "foo-qux",
            :version => '3.0'
          )
        end
        response.status.should == 404

        response.body.should =~ /Unsupported service version/
        stop_gateway(gw_pid)
      end

      it "should support provider in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo-core', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        # cf provider gateway
        svc = Service.new
        svc.label = "foo-1.0"
        svc.provider = 'cf'
        svc.url   = "http://localhost:45678"
        svc.token = 'foobar'
        svc.plans = ['free']
        svc.supported_versions = ['1.0']
        svc.save
        svc.should be_valid

        run_once = false
        shim_cf = ServiceProvisionerStub.new
        shim_cf.stubs(:provision_service).returns({:configuration => {}, :service_id => 'foo-cf', :credentials => {}})
        gw2_pid = start_gateway(svc, shim_cf)

        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => "foo-qux",
            :version => '1.0',
            :provider => 'cf'
          )
        end
        response.status.should == 200

        # invalid provider
        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => "foo-qux",
            :version => '1.0',
            :provider => 'cf2'
          )
        end
        response.status.should == 404

        # valid provider with wrong version
        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => "foo-qux",
            :version => '2.0',
            :provider => 'cf'
          )
        end
        response.status.should == 404

        stop_gateway(gw_pid)
        stop_gateway(gw2_pid)
      end
    end
  end
end
