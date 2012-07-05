class ChangeServicesIndex < ActiveRecord::Migration
  def self.up
    remove_index :services, :column => [:name, :version]
    add_index :services, [:name, :version, :provider], :unique => true
  end

  def self.down
    remove_index :services, :column => [:name, :version, :provider]
    add_index :services, [:name, :version], :unique => true
  end
end
