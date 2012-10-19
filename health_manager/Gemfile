source "http://rubygems.org"

gem 'bundler', '>= 1.0.10'
gem 'nats', '~> 0.4.24', :require => 'nats/client'
gem 'eventmachine', :git => 'https://github.com/cloudfoundry/eventmachine.git', :branch => 'release-0.12.11-cf'
gem 'em-http-request', '~> 1.0.0.beta.3', :require => 'em-http'

gem 'rack', :require => ["rack/utils", "rack/mime"]
gem 'rake'
gem 'thin'
gem 'yajl-ruby', :require => ['yajl', 'yajl/json_gem']

gem 'vcap_common', '>= 1.0.10', :git => 'https://github.com/cloudfoundry/vcap-common.git', :ref => 'cbeb8a17'
gem "vcap_logging", "~> 1.0.0", :git => 'https://github.com/cloudfoundry/common.git', :ref => 'e36886a1'
gem 'cf-uaa-client', '~> 1.2', :git => 'https://github.com/cloudfoundry/uaa.git', :ref => '603bb76ce8'

group :test do
  gem "rspec"
  gem "rcov"
  gem "ci_reporter"
end
