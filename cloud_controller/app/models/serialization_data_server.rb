class SerializationDataServer < ActiveRecord::Base
  validates_presence_of :host, :port, :token
  validates_uniqueness_of :host

  attr_accessible :host, :port, :token, :active

  def self.active_sds(staled_secs=nil)
    if staled_secs && staled_secs.is_a?(Fixnum) && staled_secs > 0
      where("active = ? AND updated_at > ?", true, staled_secs.seconds.ago)
    else
      where("active = ?", true)
    end
  end
end
