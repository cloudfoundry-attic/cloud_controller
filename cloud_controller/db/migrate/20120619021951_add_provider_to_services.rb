class AddProviderToServices < ActiveRecord::Migration
  def self.up
    add_column :services, :provider, :string
  end

  def self.down
    remove_column :services, :provider
  end
end
