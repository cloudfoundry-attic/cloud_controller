require 'secure_user_manager'

# Setup secure mode if asked
SecureUserManager.instance.setup if AppConfig[:staging][:secure]
