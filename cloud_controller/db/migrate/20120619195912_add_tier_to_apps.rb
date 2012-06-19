class AddTierToApps < ActiveRecord::Migration
  def self.up
    add_column :apps, :tier, :string
  end

  def self.down
    remove_column :apps, :tier
  end
end
