class AddRuntimeRemovedToApps < ActiveRecord::Migration
  def self.up
    add_column :apps, :runtime_removed, :boolean, :default => false
  end

  def self.down
    remove_column :apps, :runtime_removed
  end
end
