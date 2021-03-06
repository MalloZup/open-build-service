class Project < ActiveXML::Base
  has_many :package
  
  def to_s
    name.to_s
  end

  def add_package( package )
    logger.debug "adding package #{package} to project #{self}"

    if( has_element? :package )
      elem_cache = split_data_after :package
    elsif( has_element? :person )
      elem_cache = split_data_after :person
    else
      elem_cache = split_data_after :description
    end
    
    #add the new package
    @data.add_element 'package', 'name' => package.to_s, 'revision' => 1
        
    #readd the removed elements
    merge_data elem_cache
  end

  def remove_package( package )
    return nil unless package

    data.delete_element "package[@name='#{package}']"

    logger.debug "removing package '#{package}' from project #{self}"
  end

  def add_person( opt={} )
    return false unless opt[:userid] and opt[:role]
    logger.debug "adding person '#{opt[:userid]}', role '#{opt[:role]}' to project #{self.name}"

    if( has_element? :person )
      elem_cache = split_data_after :person
    else
      elem_cache = split_data_after :description
    end

    #add the new person
    @data.add_element 'person', 'userid' => opt[:userid], 'role' => opt[:role]

    merge_data elem_cache
  end

  #removes persons based on attributes
  def remove_persons( opt={} )
    xpath="person"
    if not opt.empty?
      opt_arr = []
      opt.each do |k,v|
        opt_arr << "@#{k}='#{v}'"
      end
      xpath += "[#{opt_arr.join ' and '}]"
    end
    logger.debug "removing persons using xpath '#{xpath}'"
    @data.each_element(xpath) do |e|
      @data.delete_element e
    end
  end

  #TODO: change name to add/remove_repository
  def add_target( opt={} )
    return nil if opt == {}
    target = REXML::Element.new 'repository'
    target.attributes['name'] = opt[:targetname]
    opt[:platform] =~ /(.*)\/(.*)/;
    target.add_element 'path', 'project' => $1, 'repository' => $2
    opt[:arch].to_a.each do |arch_text|
      arch = target.add_element('arch')
      arch.text = arch_text
    end

    @data.add_element target
  end

  def remove_target( target )
    return nil if not target
    return nil if not self.has_element? :repository
    
    @data.delete_element "repository[@name='#{target}']"
  end

  private

end
