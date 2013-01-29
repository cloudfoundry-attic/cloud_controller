
module CloudSpecHelpers
  # Define test scenarios for https enforcement code
  HTTPS_ENFORCEMENT_SCENARIOS = [{:protocol => "http", :appconfig_enabled => [], :user => "user", :success => true},
   {:protocol => "http", :appconfig_enabled => [], :user => "admin", :success => true},
   {:protocol => "https", :appconfig_enabled => [], :user => "user", :success => true},
   {:protocol => "https", :appconfig_enabled => [], :user => "admin", :success => true},

   # Next with https_required
   {:protocol => "http", :appconfig_enabled => [:https_required], :user => "user", :success => false},
   {:protocol => "http", :appconfig_enabled => [:https_required], :user => "admin", :success => false},
   {:protocol => "https", :appconfig_enabled => [:https_required], :user => "user", :success => true},
   {:protocol => "https", :appconfig_enabled => [:https_required], :user => "admin", :success => true},

   # Finally with https_required_for_admins
   {:protocol => "http", :appconfig_enabled => [:https_required_for_admins], :user => "user", :success => true},
   {:protocol => "http", :appconfig_enabled => [:https_required_for_admins], :user => "admin", :success => false},
   {:protocol => "https", :appconfig_enabled => [:https_required_for_admins], :user => "user", :success => true},
   {:protocol => "https", :appconfig_enabled => [:https_required_for_admins], :user => "admin", :success => true}]

  @@use_jwt_token = false
  @@use_jwt_token_with_rsa_key = false

  def self.use_jwt_token
    @@use_jwt_token
  end

  def self.use_jwt_token=(use_jwt_token)
    @@use_jwt_token = use_jwt_token
  end

  def self.use_jwt_token_with_rsa_key
    @@use_jwt_token_with_rsa_key
  end

  def self.use_jwt_token_with_rsa_key=(use_jwt_token_with_rsa_key)
    @@use_jwt_token_with_rsa_key = use_jwt_token_with_rsa_key
  end

  # Generate a handy header Hash.
  # At minimum it requires a User or email as the first argument.
  # Optionally, you can pass a second User or email which will be the 'proxy user'.
  # Finally, if you pass a String or Hash as the third argument, it will be
  # JSON-ized and used as the request body.
  def headers_for(user, proxy_user = nil, raw_data = nil, https = false)
    headers = {}
    if user
      email = User === user ? user.email : user.to_s
      if @@use_jwt_token_with_rsa_key
        UaaToken.stubs(:token_key_fetch_failure_count).returns(3)
        CF::UAA::Misc.stubs(:validation_key).returns(public_key_from_uaa())
        token_body = {"resource_ids" => ["cloud_controller"], "foo" => "bar", "email" => email}
        token_coder = CF::UAA::TokenCoder.new(AppConfig[:uaa][:resource_id],
                                              AppConfig[:uaa][:token_secret],
                                              private_key())

        token = token_coder.encode(token_body, 'RS256')
        AppConfig[:uaa][:enabled] = true
        headers['HTTP_AUTHORIZATION'] = "bearer #{token}"
      elsif @@use_jwt_token
        token_body = {"resource_ids" => ["cloud_controller"], "foo" => "bar", "email" => email}
        token_coder = CF::UAA::TokenCoder.new(AppConfig[:uaa][:resource_id],
                                              AppConfig[:uaa][:token_secret])
        token = token_coder.encode(token_body)
        AppConfig[:uaa][:enabled] = true
        headers['HTTP_AUTHORIZATION'] = "bearer #{token}"
      else
        AppConfig[:uaa][:enabled] = false
        headers['HTTP_AUTHORIZATION'] = UserToken.create(email).encode
      end
    end
    if proxy_user
      proxy_email = User === proxy_user ? proxy_user.email : proxy_user.to_s
      headers['HTTP_PROXY_USER'] = proxy_email
    end
    if raw_data
      unless String === raw_data
        raw_data = Yajl::Encoder.encode(raw_data)
      end
      headers['RAW_POST_DATA'] = raw_data
    end
    headers['X-Forwarded_Proto'] = "https" if https
    headers
  end

  # Convenience method for constructing and saving a regular user.
  def build_user(email, user_password = 'password')
    user = User.new :email => email
    user.set_and_encrypt_password user_password
    user.save!
    user
  end

  # Expected to be called in a 'before' block. Ensures that there are at least two users, one an admin.
  def build_admin_and_user
    User.admins = %w[admin@example.com]
    @admin_password ||= "ADMINpassword" if @admin.nil?
    @admin ||= build_user(User.admins.first, @admin_password)
    @user_password ||= "USERpassword" if @user.nil?
    @user ||= build_user('user@example.com', @user_password)
  end

  # Easier than bringing the usual Faker gem in.
  # Only 'hard-code' names in the specs that are meaningful.
  # If the name doesn't matter in real life, use a random one to indicate that.
  def random_name(length = 7)
    Digest::SHA1.hexdigest("#{Time.now.nsec}-#{rand(1_000_000)}").slice(0,length)
  end

  def private_key
    "-----BEGIN RSA PRIVATE KEY-----
MIIBywIBAAJhAOTeb4AZ+NwOtPh+ynIgGqa6UWNVe6JyJi+loPmPZdpHtzoqubnC
wEs6JSiSZ3rButEAw8ymgLV6iBY02hdjsl3h5Z0NWaxx8dzMZfXe4EpfB04ISoqq
hZCxchvuSDP4eQIDAQABAmEAqUuYsuuDWFRQrZgsbGsvC7G6zn3HLIy/jnM4NiJK
t0JhWNeN9skGsR7bqb1Sak2uWqW8ZqnqgAC32gxFRYHTavJEk6LTaHWovwDEhPqc
Zs+vXd6tZojJQ35chR/slUEBAjEA/sAd1oFLWb6PHkaz7r2NllwUBTvXL4VcMWTS
pN+5cU41i9fsZcHw6yZEl+ZCicDxAjEA5f3R+Bj42htNI7eylebew1+sUnFv1xT8
jlzxSzwVkoZo+vef7OD6OcFLeInAHzAJAjEAs6izolK+3ETa1CRSwz0lPHQlnmdM
Y/QuR5tuPt6U/saEVuJpkn4LNRtg5qt6I4JRAjAgFRYTG7irBB/wmZFp47izXEc3
gOdvA1hvq3tlWU5REDrYt24xpviA0fvrJpwMPbECMAKDKdiDi6Q4/iBkkzNMefA8
7HX27b9LR33don/1u/yvzMUo+lrRdKAFJ+9GPE9XFA==
-----END RSA PRIVATE KEY-----"
  end

  def public_key_from_uaa
    {:alg => 'SHA256withRSA',
     :value => "-----BEGIN RSA PUBLIC KEY-----
MGgCYQDk3m+AGfjcDrT4fspyIBqmulFjVXuiciYvpaD5j2XaR7c6Krm5wsBLOiUo
kmd6wbrRAMPMpoC1eogWNNoXY7Jd4eWdDVmscfHczGX13uBKXwdOCEqKqoWQsXIb
7kgz+HkCAwEAAQ==
-----END RSA PUBLIC KEY-----"}
  end


end
