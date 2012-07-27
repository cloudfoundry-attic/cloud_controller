require 'spec_helper'


describe "Runtime" do

  it "#all returns correct runtimes" do
    Runtime.all.find {|x| x.name == 'java'}.options.should == {'name'=>'java','description'=>"Java 6",'version'=>"1.6",'executable'=>'java'}
  end

  it '#find returns correct runtime' do
    Runtime.find('java').options.should == {'name'=> "java", 'description'=>"Java 6",'version'=>"1.6", 'executable'=>'java'}
  end

  it '#find returns nil if runtime not found' do
    Runtime.find('foo').should == nil
  end

  it "#all filters out disabled runtimes" do
    Runtime.all.find {|x| x.name == 'myruntime'}.should == nil
  end
end
