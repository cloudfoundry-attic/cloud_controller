class CreateSerializationDataServers < ActiveRecord::Migration
  def self.up
    create_table :serialization_data_servers do |t|
      t.string :host
      t.string :port
      t.string :external
      t.string :token
      t.boolean :active, :default => true

      t.timestamps
    end

    add_index :serialization_data_servers, :host
    add_index :serialization_data_servers, :external
  end

  def self.down
    remove_index :serialization_data_servers, :column => :external
    remove_index :serialization_data_servers, :column => :host

    drop_table :serialization_data_servers
  end
end
