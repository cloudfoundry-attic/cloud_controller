class AddDefaultPlanToServices < ActiveRecord::Migration
  def self.up
    add_column :services, :default_plan, :string
  end

  def self.down
    remove_column :services, :default_plan
  end
end
