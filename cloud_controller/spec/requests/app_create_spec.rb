require 'spec_helper'

describe "Creating a new App" do
  let(:data) do
    {
      'name' => random_name,
      'staging' => { 'model' => 'sinatra', 'stack' => 'ruby18' },
    }
  end

  shared_examples_for "any request to create a new app" do
    before do
      build_admin_and_user
    end

    it "is successful when given a unique name" do
      lambda do
        post app_create_path, nil, headers_for(@user.email, nil, data)
        response.should redirect_to(app_get_url(data['name']))
      end.should change(App, :count).by(1)
    end

    it "fails when given a duplicate name"
  end

  context "using conventional tokens" do
    it_should_behave_like "any request to create a new app"
  end

  context "using jwt tokens" do
    before :all do
      CloudSpecHelpers.use_jwt_token = true
    end

    it_should_behave_like "any request to create a new app"
  end

  context "using jwt tokens with RSA keys" do
    before :all do
      CloudSpecHelpers.use_jwt_token_with_rsa_key = true
    end

    it_should_behave_like "any request to create a new app"
  end

  describe "buildpack" do
    before do
      build_admin_and_user
    end

    context "when app has a valid buildpack url" do
      let(:data) do
        {
          'name' => random_name,
          'staging' => { 'model' => 'sinatra', 'stack' => 'ruby18' },
          'buildpack' => 'git://example.com/foo.git',
        }
      end

      it do
        lambda do
          post app_create_path, nil, headers_for(@user.email, nil, data)
        end.should change(App, :count).by(1)
      end
    end

    context "when app has a invalid buildpack url" do
      let(:data) do
        {
          'name' => random_name,
          'staging' => { 'model' => 'sinatra', 'stack' => 'ruby18' },
          'buildpack' => 'git@github.com:foo/bar.git',
        }
      end

      it do
        post(app_create_path, nil, headers_for(@user.email, nil, data)).should eq 400
      end
    end
  end
end
