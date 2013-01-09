require "uaa/token_coder"
require "uaa/token_issuer"
require "uaa/misc"

class UaaToken

  @uaa_token_coder ||= CF::UAA::TokenCoder.new(AppConfig[:uaa][:resource_id],
                                               AppConfig[:uaa][:token_secret])

  @token_issuer ||= CF::UAA::TokenIssuer.new(AppConfig[:uaa][:url],
                                             AppConfig[:uaa][:resource_id],
                                             AppConfig[:uaa][:client_secret])

  @id_token_issuer ||= CF::UAA::TokenIssuer.new(AppConfig[:uaa][:url],
                                               "vmc",
                                               nil)

  @token_key_fetch_failure_count = 3


  class << self

    attr_accessor :token_key_fetch_failure_count

    def is_uaa_token?(token)
      token.nil? || /\s+/.match(token.strip()).nil?? false : true
    end

    def decode_token(auth_token)
      if (auth_token.nil?)
        return nil
      end

      CloudController.logger.debug("Auth token is #{auth_token.inspect}")

      # Try to fetch the token key (public key) from the UAA
      if token_key_fetch_failure_count > 0 && !@token_key
        begin
          CF::UAA::Misc.async=true
          @token_key ||= CF::UAA::Misc.validation_key(AppConfig[:uaa][:url])

          if @token_key[:alg] == "SHA256withRSA"
            CloudController.logger.debug("token key fetched from the uaa #{@token_key.inspect}")
            @uaa_token_coder = CF::UAA::TokenCoder.new(AppConfig[:uaa][:resource_id],
                                                       AppConfig[:uaa][:token_secret],
                                                       @token_key[:value])
            CloudController.logger.info("successfully fetched public key from the uaa")
          end
        rescue => e
          self.token_key_fetch_failure_count = token_key_fetch_failure_count - 1
          CloudController.logger.warn("Failed to fetch the token key from the UAA token_key endpoint or recieved symmetric key instead")
          CloudController.logger.debug("Request to uaa/token_key OR public key init failed. #{@token_key_fetch_failure_count} retries remain. #{e.message}")
        end
      end

      token_information = nil
      begin
        if (hdr = /^bearer\s+([^.]+)/i.match(auth_token)) &&
            (hdr = CF::UAA::TokenCoder.base64url_decode(hdr[1])) &&
            CF::UAA::Util.json_parse(hdr)[:alg] == "none"
          raise CF::UAA::DecodeError, "Token signature algorithm not accepted"
        end
        token_information = @uaa_token_coder.decode(auth_token)
        CloudController.logger.info("Decoded user token #{token_information.inspect}")
      rescue => e
        CloudController.logger.error("Invalid bearer token Message: #{e.message}")
      end
      token_information[:email] if token_information
    end

    def expire_access_token
      @access_token = nil
      @user_account = nil
    end

    def access_token
      if @access_token.nil?
        #Get a new one
        @token_issuer.async = true
        @token_issuer.logger = CloudController.logger
        @access_token = @token_issuer.client_credentials_grant().auth_header
      end
      CloudController.logger.debug("access_token #{@access_token}")
      @access_token
    end

    def id_token(email, password)
      @id_token_issuer.async = true
      @id_token_issuer.logger = CloudController.logger
      id_token = @id_token_issuer.implicit_grant_with_creds(username: email, password: password).auth_header
      CloudController.logger.debug("id_token #{id_token}")
      id_token
    end

    def user_account_instance
      if @user_account.nil?
        @user_account = CF::UAA::UserAccount.new(AppConfig[:uaa][:url], UaaToken.access_token)
        @user_account.async = true
        @user_account.logger = CloudController.logger
      end
      @user_account
    end

  end

end
