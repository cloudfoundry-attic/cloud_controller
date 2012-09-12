# Copyright (c) 2009-2011 VMware, Inc.
require 'spec_helper'

#functional tests are now implemented in functional/health_manager_spec.rb

describe HealthManager do

  def build_user
    @user = ::User.find_by_email('test@example.com')
    unless @user
      @user = ::User.new(:email => "test@example.com")
      @user.set_and_encrypt_password('HASHEDPASSWORD')
      @user.save!
    end
    @user
  end

  def make_db_app_entry(appname)
    app = @user.apps.find_by_name(appname)
    unless app
      app = ::App.new(:name => appname, :owner => @user, :runtime => "ruby19", :framework => "sinatra")
      app.package_hash = random_hash
      app.staged_package_hash = random_hash
      app.state = "STARTED"
      app.package_state = "STAGED"
      app.instances = 3
      app.save!
    end
    app
  end

  def make_stats
    { :frameworks => {}, :runtimes => {}, :running => 0, :down => 0 }
  end

  def build_app(appname = 'testapp')
    @app = make_db_app_entry(appname)
    @app.set_urls(["http://#{appname}.vcap.me"])

    @droplet_entry = {
        :last_updated => @app.last_updated - 2, # take off 2 seconds so it looks 'quiescent'
        :state => 'STARTED',
        :crashes => {},
        :versions => {},
        :live_version => "#{@app.staged_package_hash}-#{@app.run_count}",
        :instances => @app.instances,
        :framework => 'sinatra',
        :runtime => 'ruby19'
    }
    @hm.update_droplet(@app)
    @app
  end

  def random_hash(len=40)
    res = ""
    len.times { res << rand(16).to_s(16) }
    res
  end

  def build_user_and_app
    build_user
    build_app
  end

  def should_publish_to_nats(message, payload)
    NATS.should_receive(:publish).with(message, payload.to_json)
  end

  after(:each) do
    VCAP::Logging.reset
  end

  after(:all) do
    ::User.destroy_all
    ::App.destroy_all
  end

  before(:each) do

    @config = {
      'mbus' => 'nats://localhost:4222/',
      'logging' => {
        'level' => ENV['LOG_LEVEL'] || 'warn',
      },
      'intervals' => {
        'database_scan' => 1,
        'droplet_lost' => 300,
        'droplets_analysis' => 0.5,
        'flapping_death' => @flapping_death = 2,
        'min_restart_delay' => @min_restart_delay = 1,
        'max_restart_delay' => @max_restart_delay = 3,
        'giveup_crash_number' => @giveup_crash_number = 5,
        'flapping_timeout' => 5,
        'restart_timeout' => 2,
        'stable_state' => -1,

      },
      'dequeueing_rate' => 50,
      'rails_environment' => 'test',
      'database_environment' => {
        'test' => {
          'adapter' => 'sqlite3',
          'database' => 'db/test.sqlite3',
          'encoding' => 'utf8'
        }
      }
    }

    @hm = HealthManager.new(@config)

    hash = Hash.new {|h,k| h[k] = 0}
    VCAP::Component.stub!(:varz).and_return(hash)
    ::User.destroy_all
    ::App.destroy_all

    build_user_and_app
  end

  def make_heartbeat_message(options = {})
    options = options.dup #copy before getting all destructive
    indices = options.delete('indices') || [0]

    droplets = []
    indices.each do |index|
      droplets << {
        'droplet' => @app.id.to_s,
        'cc_partition' => "default",
        'index' => index,
        'instance' => "badbeef-#{index}",
        'state' => 'RUNNING',
        'version' => @droplet_entry[:live_version],
        'state_timestamp' => @droplet_entry[:last_updated]
      }.merge(options)
    end
    { 'droplets' => droplets }
  end

  def make_crashed_message(options={})
    {
      'droplet' => @app.id.to_s,
      'cc_partition' => "default",
      'version' => "#{@app.staged_package_hash}-#{@app.run_count}",
      'index' => 0,
      'instance' => "badbeef-0",
      'reason' => 'CRASHED',
      'crash_timestamp' => Time.now.to_i
    }.merge(options)
  end

  def make_restart_message(options = {})
    m = {
      'droplet' => @app.id.to_s,
      'op' => 'START',
      'last_updated' => @app.last_updated.to_i,
      'version' => "#{@app.staged_package_hash}-#{@app.run_count}",
      'indices' => [0]
    }.merge(options)
  end

  def get_live_index(droplet_entry,index)
    droplet_entry[:versions].should_not be_nil
    version_entry = droplet_entry[:versions][@droplet_entry[:live_version]]
    version_entry.should_not be_nil
    version_entry[:indices][index].should_not be_nil
    version_entry[:indices][index]
  end

  describe '#perform_quantum' do
    it 'should be resilient to nil arguments' do
      @hm.perform_quantum(nil, nil)
    end
  end

  it "should detect instances that are down and send a START request" do
    stats = { :frameworks => {}, :runtimes => {}, :down => 0 }
    should_publish_to_nats "cloudcontrollers.hm.requests.default", {
      'droplet' => @app.id.to_s,
      'op' => 'START',
      'last_updated' => @app.last_updated.to_i,
      'version' => "#{@app.staged_package_hash}-#{@app.run_count}",
      'indices' => [0,1,2]
    }

    @hm.analyze_app(@app.id.to_s, @droplet_entry, stats)
    @hm.deque_a_batch_of_requests

    stats[:down].should == 3
    stats[:frameworks]['sinatra'][:missing_instances].should == 3
    stats[:runtimes]['ruby19'][:missing_instances].should == 3
  end

  it "should detect extra instances and send a STOP request" do
    stats = make_stats
    timestamp = Time.now.to_i
    version_entry = { indices: {
        0 => { :state => 'RUNNING', :timestamp => timestamp, :last_action => @app.last_updated, :instance => '0' },
        1 => { :state => 'RUNNING', :timestamp => timestamp, :last_action => @app.last_updated, :instance => '1' },
        2 => { :state => 'RUNNING', :timestamp => timestamp, :last_action => @app.last_updated, :instance => '2' },
        3 => { :state => 'RUNNING', :timestamp => timestamp, :last_action => @app.last_updated, :instance => '3' }
      }}
    should_publish_to_nats "cloudcontrollers.hm.requests.default", {
      'droplet' => @app.id.to_s,
      'op' => 'STOP',
      'last_updated' => @app.last_updated.to_i,
      'instances' => [ version_entry[:indices][3][:instance] ]
    }
    @droplet_entry[:versions][@droplet_entry[:live_version]] = version_entry

    @hm.analyze_app(@app.id.to_s, @droplet_entry, stats)

    stats[:running].should == 3
    stats[:frameworks]['sinatra'][:running_instances].should == 3
    stats[:runtimes]['ruby19'][:running_instances].should == 3
  end

  describe "spindown" do

    before(:each) do
      # ensure spindown disabled by default
      @hm.spindown_inactive_apps.should be_false

      # now create hm with spindown enabled
      @config['intervals']['inactivity_period_for_spindown'] = 2 # spindown after 2 seconds of inactivity
      @hm = HealthManager.new(@config)
      @hm.update_droplet(@app)
      droplet[:last_updated] -= 2 #to satisfy quiscence requirement

      @hm.spindown_inactive_apps.should be_true
    end

    def droplet
      @hm.droplets[@app.id.to_s]
    end

    def activity_message
      Zlib::Deflate.deflate([@app.id.to_s].to_json)
    end

    it "should update last_activity timestamp" do
      droplet[:last_activity].should be_nil
      @hm.process_active_apps_message(activity_message)
      droplet[:last_activity].should_not be_nil
      droplet[:last_activity].should <= @hm.now
    end

    it "should spindown app with no acitvity at all" do
      should_publish_to_nats('cloudcontrollers.hm.requests.default', {
                               :droplet =>  @app.id.to_s,
                               :op => :SPINDOWN
                             })

      # make hm believe that 3 seconds have elapsed
      @hm.set_now( @hm.now + 3 )

      @hm.analyze_app(@app.id.to_s, droplet, make_stats)
    end

    it "should not spindown an app with activity" do

      3.times {
        @hm.set_now( @hm.now + 1 )
        @hm.process_active_apps_message(activity_message)
      }

      @hm.analyze_app(@app.id.to_s, droplet, make_stats)
    end

    it "should not spindown inactive app with 'prod' flag set to true" do
      droplet[:prod] = true
      # make hm believe that 3 seconds have elapsed
      @hm.set_now( @hm.now + 3 )
      @hm.analyze_app(@app.id.to_s, droplet, make_stats)
    end

    it "should spindown an app with stale activity" do
      should_publish_to_nats('cloudcontrollers.hm.requests.default', {
                               :droplet =>  @app.id.to_s,
                               :op => :SPINDOWN
                             })
      @hm.process_active_apps_message(activity_message)

      # make hm believe that 3 seconds have elapsed
      @hm.set_now( @hm.now + 3 )

      @hm.analyze_app(@app.id.to_s, droplet, make_stats)
    end
  end

  it "should update its internal state to reflect heartbeat messages" do
    droplet_entries = @hm.process_heartbeat_message(make_heartbeat_message.to_json)

    droplet_entries.size.should == 1
    droplet_entry = droplet_entries[0]
    get_live_index(droplet_entry,0)[:state].should == 'RUNNING'
  end

  it "should restart an instance that exits unexpectedly" do
    ensure_non_flapping_restart
  end

  it "should exponentially delay restarts for flapping instance" do
    @flapping_death.times {
      ensure_non_flapping_restart
    }

    delay = @min_restart_delay

    (@giveup_crash_number - @flapping_death).times {
      ensure_flapping_delayed_restart(delay)
      delay *= 2
      delay = @max_restart_delay if delay > @max_restart_delay
    }
    ensure_gaveup_restarting
  end

  describe 'cc_partition' do
    it 'should ignore heartbeat with mismatched cc_partition' do
      should_publish_to_nats("cloudcontrollers.hm.requests.default",make_restart_message('indices'=>[1]))
      hb = make_heartbeat_message('indices' => [0,1,2])

      hb['droplets'][1]['cc_partition'].should == 'default'

      # changing the value will make hm ignore this heartbeat,
      # resulting in restart message being sent
      hb['droplets'][1]['cc_partition'] = 'bogus_partition'

      @hm.process_heartbeat_message(hb.to_json)
      @droplet_entry = @hm.droplets[@app.id.to_s]

      @hm.analyze_app(@app.id.to_s, @droplet_entry, make_stats)
      @hm.deque_a_batch_of_requests
    end

    it 'should interpret absent cc_partition information as "default"' do
      hb = make_heartbeat_message('indices' => [0,1,2])

      # remove cc_partition entry for instance 1.
      # the absence of value will be intreted the same as a 'default' value
      # i.e., there will be no restart.
      hb['droplets'][1].delete('cc_partition').should == 'default'

      @hm.process_heartbeat_message(hb.to_json)
      @droplet_entry = @hm.droplets[@app.id.to_s]
      @hm.analyze_app(@app.id.to_s, @droplet_entry, make_stats)
      @hm.deque_a_batch_of_requests
    end
  end

  it 'should stop instance with mismatched prod flag' do
    stats = make_stats

    # this example simulates a non-prod app, with intances 0,2 running
    # on default (non-discriminating) dea, and instance 1
    # inappropriately running on prod-only dea.  The instance 1 is
    # then stopped by hm, and restarted elsewhere.

    hb02 = make_heartbeat_message('indices' => [0,2])
    @hm.process_heartbeat_message(hb02.to_json)

    hb1 = make_heartbeat_message('indices' => [1])
    hb1['prod'] = true # augment heartbeat with dea prod status
    @hm.process_heartbeat_message(hb1.to_json)

    @droplet_entry = @hm.droplets[@app.id.to_s]

    stoppee_instance = @droplet_entry[:versions].values.first[:indices][1]

    stop_message = {
      'droplet' => @app.id.to_s,
      'op' => 'STOP',
      'last_updated' => stoppee_instance[:timestamp],
      'instances' => [stoppee_instance[:instance]]
    }
    should_publish_to_nats("cloudcontrollers.hm.requests.default", stop_message)
    should_publish_to_nats("cloudcontrollers.hm.requests.default", make_restart_message('indices'=>[1]))

    @hm.analyze_app(@app.id.to_s, @droplet_entry, stats)
    @hm.deque_a_batch_of_requests
  end

  def ensure_non_flapping_restart
    should_publish_to_nats "cloudcontrollers.hm.requests.default", make_restart_message
    @hm.process_heartbeat_message(make_heartbeat_message.to_json)
    droplet_entry = @hm.process_exited_message(make_crashed_message.to_json)
    @hm.deque_a_batch_of_requests
    get_live_index(droplet_entry,0)[:state].should == 'DOWN'
    @hm.restart_pending?(@app.id.to_s, 0).should be_false # first @flapping_death restarts are immediate.
  end

  def ensure_flapping_delayed_restart(delay)
    in_em_with_fiber do |f|
      should_publish_to_nats "cloudcontrollers.hm.requests.default", make_restart_message('flapping' => true)

      @hm.process_heartbeat_message(make_heartbeat_message.to_json)
      droplet_entry = @hm.process_exited_message(make_crashed_message.to_json)

      get_live_index(droplet_entry,0)[:state].should == 'FLAPPING'
      @hm.restart_pending?(@app.id.to_s, 0).should be_true

      # half a second before the delay elapses the restart is still pending
      EM.add_timer(delay - 0.5) do
        @hm.restart_pending?(@app.id.to_s, 0).should be_true
        @hm.deque_a_batch_of_requests
        @hm.restart_pending?(@app.id.to_s, 0).should be_true
      end

      # after delay elapses, the pending restart is initiated and is no longer pending
      EM.add_timer(delay + 0.5) do
        @hm.restart_pending?(@app.id.to_s, 0).should be_true
        @hm.deque_a_batch_of_requests
        @hm.restart_pending?(@app.id.to_s, 0).should be_false
        f.resume
      end
    end
  end

  def ensure_gaveup_restarting
    @hm.process_heartbeat_message(make_heartbeat_message.to_json)
    droplet_entry = @hm.process_exited_message(make_crashed_message.to_json)
    get_live_index(droplet_entry,0)[:state].should == 'FLAPPING'
    get_live_index(droplet_entry,0)[:crashes].should > @giveup_crash_number
    @hm.restart_pending?(@app.id.to_s, 0).should be_false
  end

  def in_em_with_fiber
    in_em do
      Fiber.new {
        yield Fiber.current
        Fiber.yield
        EM.stop
      }.resume
    end
  end

  def in_em(timeout = 10)
    EM.run do
      EM.add_timer(timeout) do
        EM.stop
        fail "Failed to complete withing allotted timeout"
      end
      yield
    end
  end

  it "should not re-start timer-triggered analysis loop if previous analysis loop is still in progress" do

    n=20
    apps = []

    n.times { |i|
      apps << make_db_app_entry("test#{i}")
    }

    VCAP::Component.varz[:running] = {}
    @hm.update_from_db

    in_em do
      @hm.analysis_in_progress?.should be_false
      @hm.analyze_all_apps.should be_true
      @hm.analysis_in_progress?.should be_true
      @hm.analyze_all_apps.should be_false
      EM.stop
    end
  end

  it "should have FIFO behavior for DEA_EVACUATION-triggered restarts" do
    apps = []

    apps << @app
    apps << build_app('test2')
    apps << build_app('test3')

    apps.each do |app|

      should_publish_to_nats("cloudcontrollers.hm.requests.default", {
                               'droplet' => app.id.to_s ,
                               'op' => 'START',
                               'last_updated' => app.last_updated.to_i,
                               'version' => "#{app.staged_package_hash}-#{app.run_count}",
                               'indices' => [0]

                             }).ordered #CRUCIAL
    end


    apps.each do |app|
      @hm.process_exited_message({
                                   'droplet' => app.id.to_s,
                                   'cc_partition' => "default",
                                   'version' => "#{app.staged_package_hash}-#{app.run_count}",
                                   'index' => 0,
                                   'instance' => 0,
                                   'reason' => 'DEA_EVACUATION',
                                   'crash_timestamp' => Time.now.to_i
                                 }.to_json)
    end
    @hm.deque_a_batch_of_requests
  end
end
