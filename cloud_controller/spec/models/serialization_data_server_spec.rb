require 'spec_helper'

describe SerializationDataServer do
  it "should transfer external to internal" do
    sds = make_sds(
                    :host => "127.0.0.1",
                    :port => "8080",
                    :external => "http://dl.vcap.me",
                    :token => "mysecret"
                  )
    internal = sds.internal
    internal.should == "http://127.0.0.1:8080"

    sds.external = "https://dl.vcap.me"
    sds.internal.should == "https://127.0.0.1:8080"
    sds.internal("https://newdl.vcap.me").should == "https://127.0.0.1:8080"
  end

  it "should select retrive active serialization_data_server" do

    sds1 = make_sds(
                    :host => "10.0.0.1",
                    :port => "8080",
                    :external => "http://dl.vcap.me",
                    :token => "mysecret",
                    :active => false
                  )

    sds2 = make_sds(
                    :host => "10.0.0.2",
                    :port => "8080",
                    :external => "http://newdl.vcap.me",
                    :token => "mysecret",
                    :active => true
                  )
    SerializationDataServer.all.count.should == 2

    SerializationDataServer.active_sds.count.should == 1

    sds1.active = true
    sds1.save
    SerializationDataServer.active_sds.count.should == 2

    SerializationDataServer.active_sds_by_external(sds2.external).count.should == 1
    SerializationDataServer.active_sds_by_external("https://mydl.vcap.me").count.should == 0
    SerializationDataServer.active_sds_by_external(nil).count.should == 0

  end

  def make_sds(opts)
    sds = SerializationDataServer.new
    opts.each do |k, v|
      sds.send("#{k}=", v)
    end
    sds.save
    sds
  end
end
