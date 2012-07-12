require 'spec_helper'
require 'support/service_controller_helper'

require 'mocha'
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
      svc.label = "foo-bar"
      svc.url   = "http://localhost:56789"
      svc.token = 'foobar'
      svc.plans = ['free', 'nonfree']
      svc.supported_versions = ["bar", "baz"]
      svc.version_aliases = {"current" => "bar"}
      svc.save
      svc.should be_valid
      @svc = svc

      request.env['CONTENT_TYPE'] = Mime::JSON
      request.env['HTTP_AUTHORIZATION'] = UserToken.create('foo@bar.com').encode
    end

    describe '#provision' do

      it "should support version in provision request" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).returns({:data => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        %w(bar baz).each do |version|
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
        shim.stubs(:provision_service).with('bar', 'free').returns({:data => {}, :service_id => 'foo', :credentials => {}})
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

      it "should fell back to default version if version mismatch" do
        shim = ServiceProvisionerStub.new
        shim.stubs(:provision_service).with('bar', 'free').returns({:data => {}, :service_id => 'foo', :credentials => {}})
        gw_pid = start_gateway(@svc, shim)

        post_msg :provision do
          LegacyVmcMessages::ProvisionRequest.new(
            :tier => 'free',
            :vendor => 'foo',
            :name  => "foo-qux",
            :version => 'qux'
          )
        end
        response.status.should == 200

        stop_gateway(gw_pid)
      end
    end
  end
end
