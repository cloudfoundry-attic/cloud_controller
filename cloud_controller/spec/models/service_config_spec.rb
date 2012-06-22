require 'spec_helper'

describe ServiceConfig do
  it "requires an alias" do
    cfg = ServiceConfig.new
    cfg.should have_at_least(1).errors_on(:alias)
  end

  it "should be valid given name, alias" do
    cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar')
    cfg.should be_valid
  end

  it "should serialize data and credentials" do
    data = {'foo' => 'bar'}
    cred = {'baz' => 'jaz'}
    cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 1, :data => data, :credentials => cred)
    cfg.save
    cfg.should be_valid

    cfg = ServiceConfig.find(cfg.id)
    cfg.should_not be_nil
    (cfg.data == data).should be_true
    (cfg.credentials == cred).should be_true
  end

  it "should enforce uniqueness on aliases" do
    cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 1)
    cfg.save
    cfg.should be_valid

    cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 1)
    cfg.save
    cfg.should_not be_valid

    # Same alias, different user
    cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 2)
    cfg.save
    cfg.should be_valid
  end


  describe '#unprovision' do
    it "must destroy itself before requesting service gateway to unprovision" do
      cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 1)
      cfg.service = Service.new

      state = states("ServiceConfig record state").starts_as('new')
      cfg.expects(:destroy).then(state.is('destroyed'))
      VCAP::Services::Api::ServiceGatewayClient.any_instance.
        stubs(:unprovision).with(:service_id => 'foo').
        when(state.is('destroyed'))
      cfg.unprovision
    end

    it "should not request unprovisioning if local state is not altered" do
      cfg = ServiceConfig.new(:name => 'foo', :alias => 'bar', :user_id => 1)
      cfg.expects(:destroy).raises("Don't erase")
      VCAP::Services::Api::ServiceGatewayClient.any_instance.
        expects(:unprovision).never
      cfg.unprovision rescue nil
      cfg.should_not be_destroyed
    end
  end

end
