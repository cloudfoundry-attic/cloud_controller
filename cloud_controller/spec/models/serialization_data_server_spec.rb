require 'spec_helper'

describe SerializationDataServer do

  it "should select retrive active serialization_data_server" do

    sds1 = make_sds(
                    :host => "10.0.0.1",
                    :port => "8080",
                    :token => "mysecret",
                    :active => false
                  )

    sds2 = make_sds(
                    :host => "10.0.0.2",
                    :port => "8080",
                    :token => "mysecret",
                    :active => true
                  )
    SerializationDataServer.all.count.should == 2

    SerializationDataServer.active_sds.count.should == 1

    sds1.active = true
    sds1.save
    SerializationDataServer.active_sds.count.should == 2

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
