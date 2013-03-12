class AddBuildpackToApps < ActiveRecord::Migration
  def self.up
    add_column :apps, :buildpack, :string
  end

  def self.down
    remove_column :apps, :buildpack
  end
end
