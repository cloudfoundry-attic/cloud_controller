class AddProdToApps < ActiveRecord::Migration
  def self.up
    add_column :apps, :prod, :boolean, :default => false
  end

  def self.down
    remove_column :apps, :prod
  end
end
