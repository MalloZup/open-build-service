require 'exceptions'

# The Role class represents a role in the database. Roles can have permissions
# associated with themselves. Roles can assigned be to roles and groups.
class Role < ActiveRecord::Base
  # roles are arranged in a tree
  acts_as_tree :order => 'title'
  # roles have n:m relations for users
  has_and_belongs_to_many :users, :uniq => true
  # roles have n:m relations to groups
  has_and_belongs_to_many :groups, :uniq => true
  # roles have n:m relations to permissions
  has_and_belongs_to_many :static_permissions, :uniq => true
  # protect users and groups from mass assigning - we want to do those
  # manually
  attr_protected :users, :parent, :static_permissions
  
  # This method returns the whole inheritance tree upwards, i.e. this role
  # and all parents as a list.
  def ancestors_and_self
    result = [self]
    
    if parent != nil
      result << parent.ancestors_and_self
    end
    
    result.flatten!
    result.uniq!

    return result
  end
  
  # This method returns itself, all children and all children of its children
  # in a flat list.
  def descendants_and_self
    result = [self]

    children.each { |child| result << child.descendants_and_self }
    
    result.flatten!
    
    return result
  end
  
  # This method returns all users assigned to this role, its children
  # or any users assigned this role has been assigned through their roles.
  def all_users
    result = []
    
    self.descendants_and_self.each do |role|
      if role == self
        result << role.users 
      else
        result << role.all_users
      end
    end
    self.all_groups.each { |group| result << group.all_users }
    
    result.flatten!
    result.uniq!
    
    return result
  end
  
  # This method returns all groups this role has been assigned to and
  # all of their children.
  def all_groups
    result = []

    self.groups.each { |group| result << group.descendants_and_self }

    result.flatten!
    result.uniq!

    return result
  end

  # This method returns all permissions granted to this role and all
  # of its parents.
  def all_static_permissions
    result = []
    
    ancestors_and_self.each { |role| result << role.static_permissions }

    result.flatten!
    result.uniq!

    return result
  end

  # We're overriding "parent=" below. So we alias the one from the acts_as_tree
  # mixin to "old_parent=".
  alias_method :old_parent=, :parent=

  # We protect the parent attribute here. If a group is given as a parent, that
  # is a descendant from this group, we raise a RecursionInTree error and stop
  # assignment.
  def parent=(value)
    if descendants_and_self.include?(value)
      raise RecursionInTree, "Trying to set parent to descendant", caller
    else
      self.old_parent = value
    end
  end
  
  # This method blocks destroying a role if it still has children. This method
  # raises a CantDeleteWithChildren exception if this error occurs. It is an 
  # ActiveRecord event hook. 
  def before_destroy
    raise CantDeleteWithChildren unless children.empty?
  end

  # Overriding this method to make "title" visible as "Name". This is called in
  # forms to create error messages.
  def human_attribute_name (attr)
    return case attr
           when 'title' then 'Name'
           else super.human_attribute_name attr
           end
  end

  protected

  # We want to validate a role's title pretty thoroughly.
  validates_uniqueness_of :title, 
                          :message => 'is the name of an already existing role.'
  validates_format_of     :title, 
                          :with => %r{^[\w \$\^\-\.#\*\+&'"]*$}, 
                          :message => 'must not contain invalid characters.'
  validates_length_of     :title, 
                          :in => 2..100, :allow_nil => true,
                          :too_long => 'must have less than 100 characters.', 
                          :too_short => 'must have more than two characters.',
                          :allow_nil => false
  
  # Implement ActiveRecords' validate method here to enforce that parents in
  # tree are actually roles.
  def validate
    errors.add(:parent, "must be a valid role.") unless parent.instance_of? Role or parent.nil?
  end
end
