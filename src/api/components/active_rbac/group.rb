require 'exceptions'

# The Group class represents a group record in the database and thus a group
# in the ActiveRbac model. Groups are arranged in trees and have a title.
# Groups have an arbitrary number of roles and users assigned to them. Child
# groups inherit all roles from their parents.
class Group < ActiveRecord::Base
  # groups are arranged in a tree
  acts_as_tree :order => 'title'
  # groups have a n:m relation to user
  has_and_belongs_to_many :users, :uniq => true
  # groups have a n:m relation to groups
  has_and_belongs_to_many :roles, :uniq => true
  # we want to protect the parent and user attribute from bulk assigning
  attr_protected :parent, :users, :roles

  # This method returns the whole inheritance tree upwards, i.e. this group
  # and all parents as a list.
  def ancestors_and_self
    result = [self]
    
    if parent != nil
      result << parent.ancestors_and_self
    end

    return result.flatten
  end
  
  # This method returns itself, all children and all children of its children
  # in a flat list.
  def descendants_and_self
    result = [self]
    
    for child in children
      result << child.descendants_and_self
    end
    
    return result.flatten
  end

  # This method returns all roles assigned to this group or any of its
  # ancessors.
  def all_roles
    result = []

    self.roles.each do |role|
      result << role.ancestors_and_self
    end
    
    result << parent.all_roles unless parent.nil?

    result.flatten!
    result.uniq!

    return result
  end
  
  # This method returns all users that have been assigned to this role. It
  # will all users directly assigned to this group and all users assigned to
  # children of this group.
  def all_users
    result = []
    
    self.descendants_and_self.each { |group| result << group.users }

    result.flatten!
    result.uniq!

    return result
  end
  
  # This method returns all permission granted to this group by its roles or
  # its parents.
  def all_static_permissions
    result = []
    
    self.all_roles.each { |role| result << role.all_static_permissions }
    
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

  # We want to validate a group's title pretty thoroughly.
  validates_uniqueness_of :title, 
                          :message => 'is the name of an already existing group.'
  validates_format_of     :title, 
                          :with => %r{^[\w \$\^\-\.#\*\+&'"]*$}, 
                          :message => 'must not contain invalid characters.'
  validates_length_of     :title, 
                          :in => 2..100, :allow_nil => true,
                          :too_long => 'must have less than 100 characters.', 
                          :too_short => 'must have more than two characters.',
                          :allow_nil => false
  
  # Implement ActiveRecords' validate method here to enforce that parents in
  # tree are actually groups.
  def validate
    errors.add(:parent, "must be a valid group.") unless parent.instance_of? Group or parent.nil?
  end
end
