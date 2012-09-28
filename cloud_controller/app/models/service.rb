class Service < ActiveRecord::Base
  LABEL_REGEX = /^\S+-\S+$/

  after_initialize :set_default_values

  # TODO - Blacklist of reserved names
  has_many :service_configs, :dependent => :destroy
  has_many :service_bindings, :through => :service_configs
  validates_presence_of :label, :url, :token
  # After support provider, the label is not unique, while the combination of label and provider is unique
  validates_uniqueness_of :label, :scope => :provider

  validates_format_of :url, :with => URI::regexp(%w(http https))
  validates_format_of :info_url, :with => URI::regexp(%w(http https)), :allow_nil => true
  validates_format_of :label, :with => LABEL_REGEX
  validate :cf_plan_id_matches_plans

  serialize :tags
  serialize :plans
  serialize :cf_plan_id
  serialize :plan_options
  serialize :binding_options
  serialize :acls
  # supported_versions in array, like ["1.0", "2.0"]
  serialize :supported_versions
  # optional alias hash for service versions
  # for example {"current" => "1.0", "next" => "2.0"}
  serialize :version_aliases

  attr_accessible :label, :token, :url, :description, :info_url, :tags, :plans, :cf_plan_id, :plan_options, :binding_options, :active, :acls, :timeout, :provider, :supported_versions, :version_aliases, :default_plan

  def set_default_values
    self.supported_versions ||= []
    self.version_aliases ||= {}
  end

  def self.active_services
    where("active = ?", true)
  end

  def label=(label)
    super
    self.name, _, self.version = self.label.rpartition(/-/) if self.label
  end

  # Predicate function that returns true if the service is visible to the supplied
  # user. False otherwise.
  #
  # There are two parts of acls. One is service acls applied to service as a whole
  # One is plan acls applied to specific service plan.
  #
  # A example of acls structure:
  # acls:
  #   users:              #service acls
  #   - foo@bar.com
  #   - foo1@bar.com
  #   wildcards:          #service acls
  #   - *@foo.com
  #   - *@foo1.com
  #   plans:
  #     plan_a:           #plan acls
  #       users:
  #       - foo2@foo.com
  #       wildcards:
  #       - *@foo1.com
  #
  # The following chart shows service visibility:
  #
  # P_ACLs\S_ACLs | Empty       | HasACLs                    |
  #   Empty       | True        | S_ACL(user)                |
  #   HasACLs     | P_ACL(user) | S_ACL(user) && P_ACL(user) |
  def visible_to_user?(user = nil, plan = nil)
    return false if !plans
    return true if !acls

    if !plan
      plans.each do |p|
        return true if visible_to_user?(user, p)
      end

      return false
    else
      p_acls = acls["plans"] && acls["plans"][plan]

      if user
        # User should match service acls and plan acls
        return validate_by_acls?(user, acls) && validate_by_acls?(user, p_acls)
      else
        if acls.has_key?("users") || acls.has_key?("wildcards")
          # Service-wide restriction by user/wildcard
          return false
        end

        if p_acls
          # Plan specific restriction
          return false
        end

        return true
      end
    end
  end

  # Return true if acls is empty or user matches user list or wildcards
  # false otherwise.
  def validate_by_acls?(user, acl)
    !acl ||
    (!acl["users"] && !acl["wildcards"]) ||
    user_in_userlist?(user, acl["users"]) ||
    user_match_wildcards?(user, acl["wildcards"])
  end

  # Returns true if the user's email is contained in the set of user emails
  # false otherwise
  def user_in_userlist?(user, userlist)
    userlist && userlist.include?(user.email)
  end

  # Returns true if user matches any of the wildcards
  # false otherwise.
  def user_match_wildcards?(user, wildcards)
    wildcards.each do |wc|
      re_str = Regexp.escape(wc).gsub('\*', '.*?')
      return true if user.email =~ /^#{re_str}$/
    end if wildcards

    false
  end

  # Returns the service represented as a legacy hash
  def as_legacy(user)
    # Synthesize tier info
    tiers = {}

    # Sort order expects to be keyed starting at 1 :/
    sort_orders = {}
    self.plans.sort.each_index do |i|
      sort_orders[self.plans[i]] = i + 1
    end

    self.plans.each do |p|
      next unless visible_to_user?(user, p)
      tiers[p] = {
        :options => {},
        :order   => sort_orders[p],  # XXX - Sort order. Synthesized for now (alphabetical), may want to add support for this to svcs api.
      }
      if self.plan_options.is_a?(Hash) && self.plan_options.has_key?(p)
        # Binding options should be included as well, but no longer
        # make sense as they are all strings...
        tiers[p][:options][:plan_option] = {
          :type        => 'value',
          :description => 'Which plan would you like to use',
          :values      => self.plan_options[p],
        }
      end
    end

    { :id      => self.id,
      :vendor  => self.name,
      :version => self.version,
      :tiers   => tiers,
      :type    => self.synthesize_service_type,
      :description => self.description || '-',
      :provider => self.provider,
      :default_plan => self.default_plan,
    }
  end

  # Service types no longer exist, synthesize one if possible to be legacy api compliant
  def synthesize_service_type
    case self.name
    when /mysql/
      'database'
    when /postgresql/
      'database'
    when /redis/
      'key-value'
    when /mongodb/
      'document'
    else
      'generic'
    end
  end

  def is_builtin?
    AppConfig.has_key?(:builtin_services) && AppConfig[:builtin_services].has_key?(self.name.to_sym) && (self.provider == nil || self.provider == "core")
  end

  def verify_auth_token(token)
    if is_builtin?
      key = (self.provider && self.provider != "core") ? self.name + "-" + self.provider : self.name
      token_a = AppConfig[:builtin_services][key.to_sym][:token]
      token_b = AppConfig[:builtin_services][key.to_sym][:token_b]
      (token_a == token || (token_b && token_b == token))
    else
      (self.token == token)
    end
  end

  def hash_to_service_offering
    svc_offering = {
      :label => self.label,
      :url   => self.url
    }
    svc_offering[:description]     = self.description     if self.description
    svc_offering[:info_url]        = self.info_url        if self.info_url
    svc_offering[:tags]            = self.tags            if self.tags
    svc_offering[:plans]           = self.plans           if self.plans
    svc_offering[:cf_plan_id]      = self.cf_plan_id      if self.cf_plan_id
    svc_offering[:plan_options]    = self.plan_options    if self.plan_options
    svc_offering[:binding_options] = self.binding_options if self.binding_options
    svc_offering[:acls]            = self.acls            if self.acls
    svc_offering[:active]          = self.active          if self.active
    svc_offering[:timeout]         = self.timeout         if self.timeout
    svc_offering[:provider]        = self.provider        if self.provider
    svc_offering[:supported_versions] = self.supported_versions if self.supported_versions
    svc_offering[:version_aliases]    = self.version_aliases    if self.version_aliases
    svc_offering[:default_plan]    = self.default_plan    if self.default_plan
    return svc_offering
  end

  def cf_plan_id_matches_plans
    # cf_plan_id either be nil,
    # or its keys must be a subset of plans
    if cf_plan_id && !(cf_plan_id.is_a?(Hash) && plans.is_a?(Array) && (cf_plan_id.keys - plans).empty?)
      errors.add(:base, "cf_plan_id does not match plans")
    end
  end

  def support_version? version
    supported_versions.include? version
  end

  def version_to_alias version
    version_aliases.each do | k, v|
      return k if v == version.to_s
    end
    nil
  end
end
