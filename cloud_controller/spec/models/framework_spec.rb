require 'spec_helper'

describe "Framework" do

  it "#all returns correct frameworks" do
    Framework.all.length.should == 5
    Framework.all.find {|x| x.name == "spring"}.options.should ==  {"name"=>"spring","runtimes"=>
      [{"java"=>{"default"=>true}}], "detection"=>[{"*.war"=>true}]}
  end

  it '#all should not list a disabled framework' do
    Framework.all.find {|x| x.name == 'myframework'}.should == nil
  end

  it "#find returns correct framework by name" do
    Framework.find("spring").options.should == {"name"=>"spring","runtimes"=>
      [{"java"=>{"default"=>true}}], "detection"=>[{"*.war"=>true}]}
  end

  it "#find returns nil if framework not found" do
    Framework.find("foo").should == nil
  end

  it "#default_runtime returns default runtime for framework when defined" do
    Framework.find("spring").default_runtime.should == "java"
  end

  it "#default_runtime returns nil if framework has no default runtime" do
    Framework.find("standalone").default_runtime.should == nil
  end

  it "#supports_runtime? returns true if runtime is supported" do
    Framework.find("spring").supports_runtime?("java").should == true
  end

  it "#supports_runtime? returns false if runtime is not supported" do
    Framework.find("spring").supports_runtime?("ruby18").should == false
  end
end
