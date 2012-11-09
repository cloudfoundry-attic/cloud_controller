require 'spec_helper'

describe AppManager do

  it 'stops app on receipt of HM message if runtime has been removed' do
    @user_a = create_user('a@foo.com', 'a')
    app = App.create(
        :name      => "foobar",
        :owner     => @user_a,
        :runtime   => "ruby19.deprecated_1.9.1p543",
        :framework => "sinatra")
    payload = { :op => "START" }
    AppManager.new(app).health_manager_message_received(payload)
    updated_app = App.find_by_name("foobar")
    updated_app.runtime.should == "ruby19.deprecated_1.9.1p543.REMOVED"
    updated_app.state.should == "STOPPED"
  end

  def create_user(email, pw)
    u = User.new(:email => email)
    u.set_and_encrypt_password(pw)
    u.save
    u.should be_valid
    u
  end
end
