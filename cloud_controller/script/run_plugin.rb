#!/usr/bin/env ruby
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __FILE__)

require 'rubygems'
require 'bundler/setup'

require 'vcap/staging/plugin/common'

unless ARGV.length == 2
  puts "Usage: run_plugin.rb [plugin name] [plugin config file]"
  exit 1
end

plugin_name, config_path = ARGV

klass  = StagingPlugin.load_plugin_for(plugin_name)
plugin = klass.from_file(config_path)
plugin.stage_application
