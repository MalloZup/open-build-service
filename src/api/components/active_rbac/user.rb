# Users wrap the users records in the database and represent users in the
# ActiveRbac model.
#
# Passwords are hashed when the object is written to the database the first 
# time. After this, only the hashed password is available. You can check
# whether the record already is in the dabase using 
# ActiveRecord::Base.new_record?

class User < ActiveRecord::Base
  # users have a n:m relation to group
  has_and_belongs_to_many :groups, :uniq => true
  # users have a n:m relation to roles
  has_and_belongs_to_many :roles, :uniq => true
  # users have 0..1 user_registration records assigned to them
  has_one :user_registration

  has_many :watched_projects

  # We don't want to assign things to roles and groups in bulk assigns.
  attr_protected :roles, :groups, :created_at, :updated_at, :last_logged_in_at, :login_failure_count, :password_hash_type
  
  # This hash contains a mapping of user states valid by default
  # and their description.
  DEFAULT_STATES = {
    'unconfirmed' => 1,
    'confirmed' => 2,
    'locked' => 3,
    'deleted' => 4
  }

  # This method returns a hash with the the available user states. 
  # By default it returns the private class constant DEFAULT_STATES.
  def self.states
    DEFAULT_STATES
  end
  
  # This method returns an array with the names of all available
  # password hash types supported by this User class.
  def self.password_hash_types
    DEFAULT_PASSWORD_HASH_TYPES
  end
  
  # This method creates a new not saveable, not changeable "Anonymous" 
  # user. We'll have to put him into the database somehow later on.
  def self.anonymous_user
    user = User.new
    user.login = 'Anonymous'
    user.freeze
    
    return user
  end
  
  # This arry contains all valid hash types.
  DEFAULT_PASSWORD_HASH_TYPES = [ 'md5' ]

  # When a record object is initialized, we set the state, password
  # hash type, indicator whether the password has freshly been set 
  # (@new_password) and the login failure count to 
  # unconfirmed/false/0 when it has not been set yet.
  def initialize (attributes = nil)
    super(attributes)

    self.state = User.states['unconfirmed'] if self.state.nil? 
    self.password_hash_type = 'md5' if self.password_hash_type.to_s == ''
    
    @new_password = false if @new_password.nil?
    @new_hash_type = false if @new_hash_type.nil?
    
    self.login_failure_count = 0 if self.login_failure_count.nil?
  end

  # Set the last login time etc. when the record is created at first.
  def before_create
    self.last_logged_in_at = Time.now
  end
  
  # Override the accessor for the "password_hash_type" property so it sets
  # the "@new_hash_type" private property to signal that the password's
  # hash method has been changed. Changing the password hash type is only
  # possible if a new password has been provided.
  def password_hash_type=(value)
    write_attribute(:password_hash_type, value)
    @new_hash_type = true
  end
  
  # After saving, we want to set the "@new_hash_type" value set to false
  # again.
  after_save '@new_hash_type = false'

  # Add accessors for "new_password" property. This boolean property is set 
  # to true when the password has been set and validation on this password is
  # required.
  attr_accessor :new_password
  
  # Generate accessors for the password confirmation property.
  attr_accessor :password_confirmation

  # Overriding the default accessor to update @new_password on setting this
  # property.
  def password=(value)
    write_attribute(:password, value)
    @new_password = true
  end
  
  # Method to update the password and confirmation at the same time. Call
  # this method when you update the password from code and don't need 
  # password_confirmation - which should really only be used when data
  # comes from forms. 
  #
  # A ussage example:
  #
  #   user = User.find(1)
  #   user.update_password "n1C3s3cUreP4sSw0rD"
  #   user.save
  #
  def update_password(pass)
    self.password_confirmation = pass
    self.password = pass
  end

  # After saving the object into the database, the password is not new any more.
  after_save '@new_password = false'

  # After validation, the password should be encrypted  
  after_validation :encrypt_password
  
  # This method writes the attribute "password" to the hashed version. It is 
  # called in the after_validation hook set by the "after_validation" command
  # above.
  # The password is only encrypted when no errors occured on validation, the
  # password is new and the password is not nil.
  # This method also sets the "password_salt" property's value used in 
  # User#hash_string.
  # After encryption, the password's "new" state is reset and the confirmation
  # is cleared.
  def encrypt_password
    if errors.count == 0 and @new_password and not password.nil?
      # generate a new 10-char long hash only Base64 encoded so things are compatible
      self.password_salt = [Array.new(10){rand(256).chr}.join].pack("m")[0..9]; 
      
      # write encrypted password to object property
      write_attribute(:password_crypted, password.crypt("os"))
      write_attribute(:password, hash_string(password))
      
      # mark password as "not new" any more
      @new_password = false
      password_confirmation = nil
    end
  end
  
  # This method returns all roles assigned to the given user - including
  # the ones he gets by being assigned a child role (i.e. the parents)
  # and the one he gets through his groups (inheritance is also considered)
  # here.
  def all_roles
    result = Array.new
    
    for role in self.roles
      result << role.ancestors_and_self
    end
    
    for group in self.groups
      result << group.all_roles
    end
    
    result.flatten!
    result.uniq!
    
    return result
  end
  
  # This method returns all groups assigned to the given user - including
  # the ones he gets by being assigned a child user.
  def all_groups
    result = Array.new
    
    for group in self.groups
      result << group.ancestors_and_self
    end
    
    result.flatten!
    result.uniq!
    
    return result
  end
  
  # This method returns true if the user is assigned the role with one of the
  # role titles given as parameters. False otherwise.
  def has_role(*role_titles)
    all_roles.detect do |role| 
      role_titles.include?(role.title)
    end
  end
 
  def logger
     RAILS_DEFAULT_LOGGER
  end 

  # This method returns true if the user is granted the permission with one
  # of the given permission titles.
  def has_permission(*permission_titles)
    all_roles.detect do |role| 
      role.static_permissions.detect do |permission|
        permission_titles.include?(permission.title)
      end
    end
  end
  
  # This method creates a new registration token for the current user. Raises 
  # a MultipleRegistrationTokens Exception if the user already has a 
  # registration token assigned to him.
  #
  # Use this method instead of creating user_registration objects directly!
  def create_user_registration
    raise unless user_registration.nil?
    
    token = UserRegistration.new
    self.user_registration = token
  end
  
  # This method expects the token for the current user. If the token is
  # correct, the user's state will be set to "confirmed" and the associated
  # "user_registration" record will be removed.
  # Returns "true" on success and "false" on failure/or the user is already
  # confirmed and/or has no "user_registration" record.
  def confirm_registration(token)
    return false if self.user_registration.nil?
    return false if user_registration.token != token
    return false unless state_transition_allowed?(state, User.states['confirmed'])
    
    self.state = User.states['confirmed']
    self.save
    user_registration.destroy
    
    return true
  end
  
  # Returns the default state of new User objects.
  def self.default_state
    User.states['unconfirmed']
  end

  # Returns true when users with the given state may log in. False otherwise.
  # The given parameter must be an integer.
  def self.state_allows_login?(state)
    state == User.states['confirmed']
  end

  # Overwrite the state setting so it backs up the initial state from
  # the database.
  def state=(value)
    @old_state = state if @old_state.nil?
    write_attribute(:state, value)
  end

  # Overriding this method to make "login" visible as "User name". This is called in
  # forms to create error messages.
  def self.human_attribute_name (attr)
    return case attr
           when 'login' then 'User name'
           else attr.humanize
           end
  end

  # This static method removes all users with state "unconfirmed" and expired
  # registration tokens.
  def self.purge_users_with_expired_registration
    registrations = UserRegistration.find :all,
                                          :conditions => [ 'expires_at < ?', Time.now.ago(2.days) ]
    registrations.each do |registration|
      registration.user.destroy
    end
  end
  
  # This static method tries to find a user with the given login and password
  # in the database. Returns the user or nil if he could not be found
  def self.find_with_credentials(login, password)
    # Find user
    user = User.find :first,
                     :conditions => [ 'login = ?', login ]
              
    # If the user could be found and the passwords equal then return the user
    if not user.nil? and user.password_equals? password
      if user.login_failure_count > 0
        user.login_failure_count = 0
        self.execute_without_timestamps { user.save }
      end
      
      return user
    end
    
    # Otherwise increase the login count - if the user could be found - and return nil
    if not user.nil?
      user.login_failure_count = user.login_failure_count + 1
      self.execute_without_timestamps { user.save }
    end
    
    return nil
  end
  
  # This method checks whether the given value equals the password when
  # hashed with this user's password hash type. Returns a boolean.
  def password_equals?(value)
    return hash_string(value) == self.password
  end

  # Sets the last login time and saves the object. Note: Must currently be 
  # called explicitely!
  def did_log_in
    self.last_logged_in_at = DateTime.now
    self.class.execute_without_timestamps { save }
  end

  # Returns true if the the state transition from "from" state to "to" state 
  # is valid. Returns false otherwise. +new_state+ must be the integer value 
  # of the state as returned by +User.states['state_name']+.
  #
  # Note that currently no permission checking is included here; It does not 
  # matter what permissions the currently logged in user has, only that the
  # state transition is legal in principle.
  def state_transition_allowed?(from, to)
    from = from.to_i
    to = to.to_i
    
    return true if from == to # allow keeping state
    
    return case from
      when User.states['unconfirmed']
        true
      when User.states['confirmed']
        (to == User.states['locked']) or (to == User.states['deleted'])
      when User.states['locked']
        (to == User.states['confirmed']) or (to == User.states['deleted'])
      when User.states['deleted']
        to == User.states['confirmed']
      when 0
        User.states.value?(to)
      else
        false
    end
  end

  protected
    # This method allows to execute a block while deactivating timestamp
    # updating.
    def self.execute_without_timestamps
      old_state = ActiveRecord::Base.record_timestamps
      ActiveRecord::Base.record_timestamps = false

      yield

      ActiveRecord::Base.record_timestamps = old_state
    end

    validates_presence_of   :login, :email, :password, :password_hash_type, :state,
                            :message => 'must be given'
    
    validates_uniqueness_of :login, 
                            :message => 'is the name of an already existing user.'
    validates_format_of     :login, 
                            :with => %r{^[\w \$\^\-\.#\*\+&'"]*$}, 
                            :message => 'must not contain invalid characters.'
    validates_length_of     :login, 
                            :in => 2..100, :allow_nil => true,
                            :too_long => 'must have less than 100 characters.', 
                            :too_short => 'must have more than two characters.'
                            
    # We want a valid email address. Note that the checking done here is very
    # rough. Email adresses are hard to validate now domain names may include
    # language specific characters and user names can be about anything anyway.
    # However, this is not *so* bad since users have to answer on their email
    # to confirm their registration.
    validates_format_of :email, 
                        :with => %r{^([\w\-\.\#\$%&!?*\'=(){}|~_]+)@([0-9a-zA-Z\-\.\#\$%&!?*\'=(){}|~]+)+$},
                        :message => 'must be a valid email address.'

    # Overriding this method to do some more validation: Password equals 
    # password_confirmation, state an password hash type being in the range
    # of allowed values.
    def validate
      # validate state and password has type to be in the valid range of values
      errors.add(:password_hash_type, "must be in the list of hash types.") unless User.password_hash_types.include? password_hash_type
      # check that the state transition is valid
      errors.add(:state, "must be in the list of states.") unless state_transition_allowed?(@old_state, state)

      # validate the password
      if @new_password and not password.nil?
        errors.add(:password, 'must have between 6 and 64 characters.') unless password.length >= 6 and password.length <= 64
        errors.add(:password, 'must match the confirmation.') unless password_confirmation == password
        errors.add(:password, 'must not contain invalid characters.') unless password =~ %r{^[\w\.\- !?(){}|~*_]+$}
      end
      
      # check that the password hash type has not been set if no new password
      # has been provided
      if @new_hash_type and not (@new_password or password.nil?)
        errors.add(:password_hash_type, 'cannot be changed unless a new password has been provided.')
      end
    end

  private
  
    # Hashes the given parameter by the selected hashing method. It uses the
    # "password_salt" property's value to make the hashing more secure.
    def hash_string(value)
      return case password_hash_type
             when 'md5' then Digest::MD5.hexdigest(value + self.password_salt)
             end
    end 
end
