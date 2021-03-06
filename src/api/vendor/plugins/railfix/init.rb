# Plugin:     rbac_railfix
# Author:     Manuel Holtgrewe <purestorm@ggnore.net>
#
# ActiveRBAC: 0.2
# Rails:      0.14.2
#
# This plugin overrides some of RoR's classes. Namely it fixes the following 
# bugs:
#
#  * http://dev.rubyonrails.com/ticket/2019 - A problem with habtm and :uniq

# ----------------------------------------------------------
# Fix http://dev.rubyonrails.com/ticket/2019
class ActiveRecord::Associations::HasAndBelongsToManyAssociation < ActiveRecord::Associations::AssociationCollection
  # Overriding this method here to heed the :uniq property.
  def <<(*records)
    result = true
    load_target
    @owner.transaction do
      flatten_deeper(records).each do |record|
        raise_on_type_mismatch(record)
        callback(:before_add, record)
        unless (@options[:uniq] and @target.include? record)
          result &&= insert_record(record) unless @owner.new_record?
          @target << record
        end
        callback(:after_add, record)
      end
    end

    result and self
  end
end
# ----------------------------------------------------------
