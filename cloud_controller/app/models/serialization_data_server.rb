class SerializationDataServer < ActiveRecord::Base
  validates_presence_of :host, :port, :external, :token
  validates_uniqueness_of :host

  attr_accessible :host, :port, :external, :token, :active

  def self.active_sds
    where("active = ?", true)
  end

  def self.active_sds_by_external(myexternal)
    where("external = ? AND active =?",myexternal,true)
  end

  def internal(myexternal=nil)
    myexternal ||= external
    # transfer external to internal
    uri = URI.parse(myexternal)
    uri.host=host
    uri.port=port.to_i
    uri.to_s
  end

end
