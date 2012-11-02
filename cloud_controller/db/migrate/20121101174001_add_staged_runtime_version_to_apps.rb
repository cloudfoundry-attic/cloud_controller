require File.expand_path('../../../app/models/runtime', __FILE__)

class AddStagedRuntimeVersionToApps < ActiveRecord::Migration

  def self.up
    add_column :apps, :staged_runtime_version, :string
    # We've yet to change the version associated with a particular runtime,
    # so populate existing apps' staged_runtime_version based on the current version.
    Runtime.all.each do |runtime|
      execute "UPDATE apps SET staged_runtime_version='#{runtime.version}' where runtime='#{runtime.name}'"
    end
  end

  def self.down
    remove_column :apps, :staged_runtime_version
  end
end
