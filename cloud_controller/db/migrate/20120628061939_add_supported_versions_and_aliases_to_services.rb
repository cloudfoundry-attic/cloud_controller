class AddSupportedVersionsAndAliasesToServices < ActiveRecord::Migration
  def self.up
    add_column :services, :supported_versions, :text
    add_column :services, :version_aliases, :text
  end

  def self.down
    remove_column :services, :version_aliases
    remove_column :services, :supported_versions
  end
end
