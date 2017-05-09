class AddPlanDescriptionsToServices < ActiveRecord::Migration
  def self.up
    add_column :services, :plan_descriptions, :string
  end

  def self.down
    remove_column :services, :plan_descriptions
  end
end
