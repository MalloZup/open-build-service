require "rexml/document"

class SourceController < ApplicationController
  validate_action :index => :directory, :packagelist => :directory, :filelist => :directory
  validate_action :project_meta => :project, :package_meta => :package, :pattern_meta => :pattern
 
  skip_before_filter :extract_user, :only => [:file, :project_meta] 

  def index
    # ACL(index): projects with flag 'access' are not listed
    projectlist
  end

  def projectlist
    if request.post?
      dispatch_command
    elsif request.get?
      if params.has_key? :deleted
        if @http_user.is_admin?
          pass_to_backend 
        else
          render_error :status => 403, :errorcode => 'no_permission_for_deleted', 
                       :message => "only admins can see deleted projects"
        end
      else
        dir = Project.find :all
        # ACL(projectlist): projects with flag 'access' are not listed
        accessprjs = DbProject.find( :all, :joins => "LEFT OUTER JOIN flags f ON f.db_project_id = db_projects.id", :conditions => [ "f.flag = 'access'", "ISNULL(f.repo)", "ISNULL(f.architecture_id)"] )
        accessprjs.each do |prj|
          dir.delete_element("//entry[@name='#{prj.name}']") if prj.disabled_for?('access', nil, nil) and not @http_user.can_access?(prj)
        end
        render :text => dir.dump_xml, :content_type => "text/xml"
      end
    end
  end

  def index_project
    project_name = params[:project]
    pro = DbProject.find_by_name project_name
    # ACL(index_project): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    if pro and pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end
    if pro.nil?
      unless params[:cmd] == "undelete" or request.get?
        render_error :status => 404, :errorcode => 'unknown_project',
          :message => "Unknown project '#{project_name}'"
        return
      end
    elsif params[:cmd] == "undelete"
      render_error :status => 403, :errorcode => 'create_project_no_permission',
          :message => "Can not undelete, project exists already '#{project_name}'"
      return
    end
    
    if request.get?
      if params.has_key? :deleted
        pass_to_backend
      else
        # ACL(index_project): private projects appear as empty
        if pro and pro.enabled_for?('privacy', nil, nil) and not @http_user.can_private_view?(pro)
          render :text => '<directory count="0"></directory>', :content_type => "text/xml"
        else
          if pro
            @dir = Package.find :all, :project => project_name
            render :text => @dir.dump_xml, :content_type => "text/xml"
          else
            pass_to_backend
          end
        end
      end
      return
    elsif request.delete?
      unless @http_user.can_modify_project?(pro)
        logger.debug "No permission to delete project #{project_name}"
        render_error :status => 403, :errorcode => 'delete_project_no_permission',
          :message => "Permission denied (delete project #{project_name})"
        return
      end

      #deny deleting if other packages use this as develproject
      unless pro.develpackages.empty?
        msg = "Unable to delete project #{pro.name}; following packages use this project as develproject: "
        msg += pro.develpackages.map {|pkg| pkg.db_project.name+"/"+pkg.name}.join(", ")
        render_error :status => 400, :errorcode => 'develproject_dependency',
          :message => msg
        return
      end
      #check all packages, if any get refered as develpackage
      pro.db_packages.each do |pkg|
        msg = ""
        pkg.develpackages do |dpkg|
          if pro != dpkg.db_project
            msg += dpkg.db_project.name + "/" + dkg.name + ", "
          end
        end
        unless msg == ""
          render_error :status => 400, :errorcode => 'develpackage_dependency',
            :message => "Unable to delete package #{pkg.name}; following packages use this package as devel package: #{msg}"
          return
        end
      end

      #find linking repos
      lreps = Array.new
      pro.repositories.each do |repo|
        repo.linking_repositories.each do |lrep|
          lreps << lrep
        end
      end

      if lreps.length > 0
        if params[:force] and not params[:force].empty?
          #replace links to this projects with links to the "deleted" project
          del_repo = DbProject.find_by_name("deleted").repositories[0]
          lreps.each do |link_rep|
            link_rep.path_elements.find(:all).each { |pe| pe.destroy }
            link_rep.path_elements.create(:link => del_repo, :position => 1)
            link_rep.save
            #update backend
            link_rep.db_project.store
          end
        else
          lrepstr = lreps.map{|l| l.db_project.name+'/'+l.name}.join "\n"
          render_error :status => 403, :errorcode => "repo_dependency",
            :message => "Unable to delete project #{project_name}; following repositories depend on this project:\n#{lrepstr}\n"
          return
        end
      end

      #destroy all packages
      pro.db_packages.each do |pack|
        DbPackage.transaction do
          logger.info "destroying package #{pack.name}"
          pack.destroy
        end
      end

      DbProject.transaction do
        logger.info "destroying project #{pro.name}"
        pro.destroy
        logger.debug "delete request to backend: /source/#{pro.name}"
        Suse::Backend.delete "/source/#{pro.name}"
      end

      render_ok
      return
    elsif request.post?
      cmd = params[:cmd]

      if 'undelete' == cmd
        unless @http_user.can_create_project?(project_name)
          render_error :status => 403, :errorcode => "cmd_execution_no_permission",
            :message => "no permission to execute command '#{cmd}'"
          return
        end
        dispatch_command

        # read meta data from backend to restore database object
        path = request.path + "/_meta"
        Project.new(backend_get(path)).save

        # restore all package meta data objects in DB
        backend_pkgs = Collection.find :package, :match => "@project='#{params[:project]}'"
        backend_pkgs.each_package do |package|
          path = request.path + "/" + package.name + "/_meta"
          Package.new(backend_get(path), :project => params[:project]).save
        end
        return
      end

      if @http_user.can_modify_project?(pro) or cmd == "showlinked"
        dispatch_command
      else
        render_error :status => 403, :errorcode => "cmd_execution_no_permission",
          :message => "no permission to execute command '#{cmd}'"
        return
      end
    else
      render_error :status => 400, :errorcode => "illegal_request",
        :message => "illegal POST request to #{request.request_uri}"
    end
  end

  # FIXME: for OBS 3, api of branch and copy calls have target and source in the opossite place
  def index_package
    valid_http_methods :get, :delete, :post
    required_parameters :project, :package
    project_name = params[:project]
    package_name = params[:package]
    cmd = params[:cmd]
    deleted = params.has_key? :deleted

    # list of commands which are allowed even when the project has the package only via a project link
    read_commands = ['diff', 'branch', 'linkdiff', 'showlinked']

    prj = DbProject.find_by_name(project_name)
    unless prj
      # Check if this is a package via project link to a remote OBS instance
      answer = Suse::Backend.get(request.path)
      if answer
        # exist remote
        if request.get?
            pass_to_backend
            return
        end
        if request.post? and cmd == "showlinked"
            dispatch_command
            return
        end
      end
      render_error :status => 404, :errorcode => "unknown_project",
        :message => "Unknown project '#{project_name}'"
      return
    end
    if request.get? or ( request.post? and read_commands.include?(cmd) )
      # include project links on get or for diff and branch command
      pkg = prj.find_package(package_name)
    else
      # allow operations only for local packages
      pkg = prj.db_packages.find_by_name(package_name)
    end
    # ACL(index_package): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package): if private view is on behave like pkg without any src files
    if pkg and pkg.enabled_for?('privacy', nil, nil) and not @http_user.can_private_view?(pkg)
      render_ok
      return
    end

    # package may not exist currently here, but can we work anyway with it ?
    unless deleted.blank? and not request.delete?
      unless package_name == "_project" or pkg or DbProject.find_remote_project(project_name)
        render_error :status => 404, :errorcode => "unknown_package",
          :message => "unknown package '#{package_name}' in project '#{project_name}'"
        return
      end
    end

    if request.get?
      pass_to_backend
      return
    elsif request.delete?
      if package_name == "_project"
        render_error :status => 403, :errorcode => "delete_package_no_permission",
          :message => "_project package can not be deleted."
        return
      end

      if not @http_user.can_modify_package?(pkg)
        render_error :status => 403, :errorcode => "delete_package_no_permission",
          :message => "no permission to delete package #{package_name}"
        return
      end
      
      #deny deleting if other packages use this as develpackage
      # Shall we offer a --force option here as well ?
      # Shall we ask the other package owner accepting to be a devel package ?
      unless pkg.develpackages.empty?
        msg = "Unable to delete package #{pkg.name}; following packages use this package as devel package: "
        msg += pkg.develpackages.map {|dp| dp.db_project.name+"/"+dp.name}.join(", ")
        render_error :status => 400, :errorcode => 'develpackage_dependency',
          :message => msg
        return
      end

      DbPackage.transaction do
        pkg.destroy
        Suse::Backend.delete "/source/#{project_name}/#{package_name}"
        if package_name == "_product"
          update_product_autopackages
        end
      end
      render_ok
    elsif request.post?
      if ['undelete'].include?(cmd) 
        unless @http_user.can_modify_project?(prj)
          render_error :status => 403, :errorcode => "cmd_execution_no_permission",
            :message => "no permission to execute command '#{cmd}'"
          return
        end
        dispatch_command

        # read meta data from backend to restore database object
        path = request.path + "/_meta"
        Package.new(backend_get(path), :project => params[:project]).save
        return
      end

      if pkg.nil? and not cmd == "showlinked"
        unless @http_user.can_modify_project?(prj)
          render_error :status => 403, :errorcode => "cmd_execution_no_permission",
            :message => "no permission to execute command '#{cmd}' for not existing package"
          return
        end
      elsif not read_commands.include?(cmd) and not @http_user.can_modify_package?(pkg)
        render_error :status => 403, :errorcode => "cmd_execution_no_permission",
          :message => "no permission to execute command '#{cmd}'"
        return
      end
      
      dispatch_command
    end
  end

  # updates packages automatically generated in the backend after submitting a product file
  def update_product_autopackages
    # ACL(update_product_autopackages) TODO: check if this needs to be instrumented
    backend_pkgs = Collection.find :id, :what => 'package', :match => "@project='#{params[:project]}' and starts-with(@name,'_product:')"
    b_pkg_index = backend_pkgs.each_package.inject(Hash.new) {|hash,elem| hash[elem.name] = elem; hash}
    frontend_pkgs = DbProject.find_by_name(params[:project]).db_packages.find(:all, :conditions => "name LIKE '_product:%'")
    f_pkg_index = frontend_pkgs.inject(Hash.new) {|hash,elem| hash[elem.name] = elem; hash}

    all_pkgs = [b_pkg_index.keys, f_pkg_index.keys].flatten.uniq

    wt_state = ActiveXML::Config.global_write_through
    begin
      ActiveXML::Config.global_write_through = false
      all_pkgs.each do |pkg|
        if b_pkg_index.has_key?(pkg) and not f_pkg_index.has_key?(pkg)
          # new autopackage, import in database
          Package.new(b_pkg_index[pkg].dump_xml, :project => params[:project]).save
        elsif f_pkg_index.has_key?(pkg) and not b_pkg_index.has_key?(pkg)
          # autopackage was removed, remove from database
          f_pkg_index[pkg].destroy
        end
      end
    ensure
      ActiveXML::Config.global_write_through = wt_state
    end
  end

  # /source/:project/_attribute/:attribute
  # /source/:project/:package/_attribute/:attribute
  # /source/:project/:package/:binary/_attribute/:attribute
  def attribute_meta
    valid_http_methods :get, :post, :delete
    params[:user] = @http_user.login if @http_user

    binary=nil
    binary=params[:binary] if params[:binary]

    if params[:package]
      @attribute_container = DbPackage.find_by_project_and_name(params[:project], params[:package])
      unless @attribute_container
        render_error :message => "Unknown package '#{params[:project]}/#{params[:package]}'",
          :status => 404, :errorcode => "unknown_package"
        return
      end
    else
      @attribute_container = DbProject.find_by_name(params[:project])
      unless @attribute_container
        render_error :message => "Unknown project '#{params[:project]}'",
          :status => 404, :errorcode => "unknown_project"
        return
      end
    end

    # ACL(attribute_meta): in case of access, project or package is really hidden
    if @attribute_container and (@attribute_container.disabled_for?('access', nil, nil) and not @http_user.can_access?(@attribute_container))
      if params[:package]
        render_error :message => "Unknown package '#{params[:project]}/#{params[:package]}'",
        :status => 404, :errorcode => "unknown_package"
        return
      else
        render_error :message => "Unknown project '#{params[:project]}'",
        :status => 404, :errorcode => "unknown_project"
        return
      end
    end

    # is the attribute type defined at all ?
    if params[:attribute]
      at = AttribType.find_by_name(params[:attribute])
      unless at
        render_error :status => 403, :errorcode => "not_existing_attribute", 
          :message => "Attribute is not defined in system"
        return
      end
    end

    if request.get?
      params[:binary]=binary if binary
      render :text => @attribute_container.render_attribute_axml(params), :content_type => 'text/xml'
      return
    end

    if request.post?
      begin
        req = BsRequest.new(request.body.read)
        req.data # trigger XML parsing
      rescue ActiveXML::ParseError => e
        render_error :message => "Invalid XML",
          :status => 400, :errorcode => "invalid_xml"
        return
      end
    end

    # permission checking
    if params[:attribute]
      aname = params[:attribute]
      name_parts = aname.split(/:/)
      if name_parts.length != 2
        raise ArgumentError, "attribute '#{aname}' must be in the $NAMESPACE:$NAME style"
      end
      unless @http_user.can_create_attribute_in? @attribute_container, :namespace => name_parts[0], :name => name_parts[1]
        render_error :status => 403, :errorcode => "change_attribute_no_permission", 
          :message => "user #{user.login} has no permission to change attribute"
        return
      end
    else
      if request.post?
        req.each_attribute do |attr|
          begin
            can_create = @http_user.can_create_attribute_in? @attribute_container, :namespace => attr.namespace, :name => attr.name
          rescue ActiveRecord::RecordNotFound => e
            render_error :status => 404, :errorcode => "not_found",
              :message => e.message
            return
          rescue ArgumentError => e
            render_error :status => 400, :errorcode => "change_attribute_attribute_error",
              :message => e.message
            return
          end
          unless can_create
            render_error :status => 403, :errorcode => "change_attribute_no_permission", 
              :message => "user #{user.login} has no permission to change attribute"
            return
          end
        end
      else
        render_error :status => 403, :errorcode => "internal_error", 
          :message => "INTERNAL ERROR: unhandled request"
        return
      end
    end

    # execute action
    if request.post?
      req.each_attribute do |attr|
        begin
          @attribute_container.store_attribute_axml(attr, binary)
        rescue DbProject::SaveError => e
          render_error :status => 403, :errorcode => "save_error", :message => e.message
          return
        rescue DbPackage::SaveError => e
          render_error :status => 403, :errorcode => "save_error", :message => e.message
          return
        end
      end
      @attribute_container.store
      render_ok
    elsif request.delete?
      @attribute_container.find_attribute(name_parts[0], name_parts[1],binary).destroy
      @attribute_container.store
      render_ok
    else
      render_error :message => "INTERNAL ERROR: Unhandled operation",
        :status => 404, :errorcode => "unknown_operation"
    end
  end

  # /source/:project/_pattern/:pattern
  def pattern_meta
    valid_http_methods :get, :put, :delete

    params[:user] = @http_user.login if @http_user
    
    @project = DbProject.find_by_name params[:project]
    unless @project
      render_error :message => "Unknown project '#{params[:project]}'",
        :status => 404, :errorcode => "unknown_project"
      return
    end

    # ACL(pattern_meta): in case of access, project or package is really hidden
    if  @project.disabled_for?('access', nil, nil) and not @http_user.can_access?(@project)
      render_error :message => "Unknown project '#{params[:project]}'",
      :status => 404, :errorcode => "unknown_project"
      return
    end

    if request.get?
      pass_to_backend
    else
      # PUT and DELETE
      permerrormsg = nil
      if request.put?
        permerrormsg = "no permission to store pattern"
      elsif request.delete?
        permerrormsg = "no permission to delete pattern"
      end

      unless @http_user.can_modify_project? @project
        logger.debug "user #{user.login} has no permission to modify project #{@project}"
        render_error :status => 403, :errorcode => "change_project_no_permission", 
          :message => permerrormsg
        return
      end
      
      path = request.path + build_query_from_hash(params, [:rev, :user, :comment])
      pass_to_backend path
    end
  end

  # GET /source/:project/_pattern
  def index_pattern
    valid_http_methods :get

    @project = DbProject.find_by_name(params[:project])
    unless @project
      render_error :message => "Unknown project '#{params[:project]}'",
        :status => 404, :errorcode => "unknown_project"
      return
    end
    
    # ACL(index_pattern): in case of access, project or package is really hidden
    if  @project.disabled_for?('access', nil, nil) and not @http_user.can_access?(@project)
      render_error :message => "Unknown project '#{params[:project]}'",
      :status => 404, :errorcode => "unknown_project"
      return
    end

    pass_to_backend
  end

  def project_meta
    valid_http_methods :get, :put
    required_parameters :project

    project_name = params[:project]

    return unless extract_user
    params[:user] = @http_user.login

    @project = DbProject.find_by_name( project_name )
    # ACL(project_meta): if access is set, this behaves like project non existing
    if @project and @project.disabled_for?('access', nil, nil) and not @http_user.can_access?(@project)
      render_error :message => "Unknown project '#{project_name}'",
      :status => 404, :errorcode => "unknown_project"
      return
    end

    if request.get?
      if @project
        render :text => @project.to_axml(params[:view]), :content_type => 'text/xml'
      elsif DbProject.find_remote_project(project_name)
        # project from remote buildservice, get metadata from backend
        pass_to_backend
      else
        render_error :message => "Unknown project '#{project_name}'",
        :status => 404, :errorcode => "unknown_project"
      end
      return
    end

    #assemble path for backend
    path = request.path
    path += build_query_from_hash(params, [:user, :comment, :rev])

    if request.put?
      unless valid_project_name? project_name
        render_error :status => 400, :errorcode => "invalid_project_name",
          :message => "invalid project name '#{project_name}'"
        return
      end

      # Need permission
      logger.debug "Checking permission for the put"
      allowed = false
      request_data = request.raw_post

      @project = DbProject.find_by_name( project_name )
      if @project
        #project exists, change it
        unless @http_user.can_modify_project? @project
          logger.debug "user #{user.login} has no permission to modify project #{@project.name}"
          render_error :status => 403, :errorcode => "change_project_no_permission", 
            :message => "no permission to change project"
          return
        end
      else
        #project is new
        unless @http_user.can_create_project? project_name
          logger.debug "Not allowed to create new project"
          render_error :status => 403, :errorcode => 'create_project_no_permission',
            :message => "not allowed to create new project '#{project_name}'"
          return
        end
      end

      # the following code checks if the target project of a linked project exists or is ACL protected
      rdata = REXML::Document.new(request.raw_post.to_s)
      rdata.elements.each("project/link") do |e|
        tproject_name = e.attributes["project"]
        tprj = DbProject.find_by_name(tproject_name)
        if tprj.nil?
          render_error :status => 404, :errorcode => 'not_found',
          :message => "The link target project #{tproject_name} does not exist"
          return
        end

        # ACL(project_meta): project link to project with access behaves like target project not existing
        if tprj.disabled_for?('access', nil, nil) and not @http_user.can_access?(tprj)
          render_error :status => 404, :errorcode => 'not_found',
          :message => "The link target project #{tproject_name} does not exist"
          return
        end

        # ACL(project_meta): project link to project with sourceaccess gives permisson denied
        if tprj.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(tprj)
          render_error :status => 403, :errorcode => "source_access_no_permission",
          :message => "No permission for link target project #{tproject_name}"
          return
        end
        logger.debug "project #{project_name} link checked against #{tproject_name} projects permission"
      end

      p = Project.new(request_data, :name => project_name)

      if p.name != project_name
        render_error :status => 400, :errorcode => 'project_name_mismatch',
          :message => "project name in xml data does not match resource path component"
        return
      end

      if (p.has_element? :remoteurl or p.has_element? :remoteproject) and not @http_user.is_admin?
        render_error :status => 403, :errorcode => "change_project_no_permission",
          :message => "admin rights are required to change remoteurl or remoteproject"
        return
      end

      p.add_person(:userid => @http_user.login) unless @project
      p.save

      render_ok
    else
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: POST #{request.path}"
    end
  end

  def project_config
    valid_http_methods :get, :put

    #check if project exists
    unless (@project = DbProject.find_by_name(params[:project]))
      render_error :status => 404, :errorcode => 'project_not_found',
        :message => "Unknown project #{params[:project]}"
      return
    end

    #assemble path for backend
    params[:user] = @http_user.login

    # ACL(project_config): in case of access, project is really hidden, accessing says project is not existing
    if @project and (@project.disabled_for?('access', nil, nil) and not @http_user.can_access?(@project))
      render_error :status => 404, :errorcode => 'project_not_found',
        :message => "Unknown project #{params[:project]}"
      return
    end

    if request.get?
      path = request.path
      path += build_query_from_hash(params, [:rev])
      pass_to_backend path
      return
    end

    #assemble path for backend
    path = request.path
    path += build_query_from_hash(params, [:user, :comment])

    if request.put?
      unless @http_user.can_modify_project?(@project)
        render_error :status => 403, :errorcode => 'put_project_config_no_permission',
          :message => "No permission to write build configuration for project '#{params[:project]}'"
        return
      end

      pass_to_backend path
      return
    end
    render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: #{request.path}"
  end

  def project_pubkey
    valid_http_methods :get, :delete

    #assemble path for backend
    params[:user] = @http_user.login if request.delete?
    path = request.path
    path += build_query_from_hash(params, [:user, :comment, :rev])

    #check if project exists
    unless prj = DbProject.find_by_name(params[:project])
      prj, pro_name = DbProject.find_remote_project(params[:project])
      unless request.get? and prj
        render_error :status => 404, :errorcode => "project_not_found",
          :message => "Unknown project '#{params[:project]}'"
        return
      end
    end

    # ACL(project_pubkey): in case of access, project or package is really hidden
    if prj and prj.disabled_for?('access', nil, nil) and not @http_user.can_access?(prj)
      render_error :message => "Unknown project '#{params[:project]}'",
      :status => 404, :errorcode => "project_not_found"
      return
    end

    if request.get?
      pass_to_backend path
    elsif request.delete?
      #check for permissions
      unless @http_user.can_modify_project?(prj)
        render_error :status => 403, :errorcode => 'delete_project_pubkey_no_permission',
          :message => "No permission to delete public key for project '#{params[:project]}'"
        return
      end

      pass_to_backend path
      return
    end
  end

  def update_package_meta(project_name, package_name, request_data, user=nil, comment=nil)
    # ACL(update_package_meta) TODO: check if this needs to be instrumented
    allowed = false
    # Try to fetch the package to see if it already exists
    @package = Package.find( package_name, :project => project_name )

    if @package
      # Being here means that the package already exists
      allowed = permissions.package_change? @package
      if allowed
        @package = Package.new( request_data, :project => project_name, :name => package_name )
      else
        logger.debug "user #{user} has no permission to change package #{@package}"
        render_error :status => 403, :errorcode => "change_package_no_permission",
          :message => "no permission to change package"
        return
      end
    else
      # Ok, the package is new
      allowed = permissions.package_create?( project_name )

      if allowed
        #FIXME: parameters that get substituted into the url must be specified here... should happen
        #somehow automagically... no idea how this might work
        @package = Package.new( request_data, :project => project_name, :name => package_name )
      else
        # User is not allowed by global permission.
        logger.debug "Not allowed to create new packages"
        render_error :status => 403, :errorcode => "create_package_no_permission",
          :message => "no permission to create package for project #{project_name}"
        return
      end
    end

    if allowed
      if( @package.name != package_name )
        render_error :status => 400, :errorcode => 'package_name_mismatch',
          :message => "package name in xml data does not match resource path component"
        return
      end

      begin
        @package.save
      rescue DbPackage::CycleError => e
        render_error :status => 400, :errorcode => 'devel_cycle', :message => e.message
        return
      end
      render_ok
    else
      logger.debug "user #{user} has no permission to write package meta for package #{@package}"
    end
  end
  private :update_package_meta

  def package_meta
    valid_http_methods :put, :get
    required_parameters :project, :package
   
    project_name = params[:project]
    package_name = params[:package]

    unless pro = DbProject.find_by_name(project_name)
      pro, pro_name = DbProject.find_remote_project(project_name)
      unless request.get? and pro
        render_error :status => 404, :errorcode => "unknown_project",
          :message => "Unknown project '#{project_name}'"
        return
      end
    end

    unless valid_package_name? package_name
      render_error :status => 400, :errorcode => "invalid_package_name",
        :message => "invalid package name '#{package_name}'"
      return
    end

    pack = pro.find_package( package_name )

    # ACL(package_meta): in case of access, project is really hidden, accessing says project is not existing
    if pack and (pack.disabled_for?('access', nil, nil) and not @http_user.can_access?(pack))
      render_error :message => "Unknown package '#{project_name}/#{package_name}'",
      :status => 404, :errorcode => "unknown_package"
      return
    end

    if request.get?
      if pack.nil? or params.has_key?(:rev)
        # check if this comes from a remote project, also true for _project package
        # or if rev it specified we need to fetch the meta from the backend
        answer = Suse::Backend.get(request.path)
        if answer
          render :text => answer.body.to_s, :content_type => 'text/xml'
        else
          render_error :status => 404, :errorcode => "unknown_package",
            :message => "Unknown package '#{package_name}'"
        end
        return
      end

      render :text => pack.to_axml(params[:view]), :content_type => 'text/xml'
    else
      update_package_meta(project_name, package_name, request.raw_post, @http_user.login, params[:comment])
    end
  end

  def file
    valid_http_methods :get, :delete, :put
    project_name = params[:project]
    package_name = params[:package]
    file = params[:file]
    path = "/source/#{CGI.escape(project_name)}/#{CGI.escape(package_name)}/#{CGI.escape(file)}"

    #authenticate
    return unless extract_user
    params[:user] = @http_user.login

    pack = DbPackage.find_by_project_and_name(project_name, package_name)
    if package_name == "_project"
      prj = DbProject.find_by_name(project_name)
      if prj.nil?
        render_error :status => 403, :errorcode => 'not_found',
          :message => "The given project #{project_name} does not exist"
        return
      end
      allowed = permissions.project_change? prj
    else
      if pack.nil? and request.get?
        # Check if this is a package on a remote OBS instance
        answer = Suse::Backend.get(request.path)
        if answer
          pass_to_backend
          return
        end
      end
      if pack.nil? and package_name != "_project"
        render_error :status => 403, :errorcode => 'not_found',
          :message => "The given package #{package_name} does not exist in project #{project_name}"
        return
      end
      allowed = permissions.package_change? pack
    end

    # ACL(file): access behaves like project not existing
    if pack and pack.disabled_for?('access', nil, nil) and not @http_user.can_access?(pack)
      render_error :status => 404, :errorcode => 'not_found',
      :message => "The given package #{package_name} does not exist in project #{project_name}"
      return
    end

    # ACL(file): source access gives permisson denied
    if pack and pack.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pack)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{package_name}, project #{project_name}"
      return
    end

    # ACL(file): lookup via :rev is prevented now by backend if $nosharedtrees is set
    if request.get?
      path += build_query_from_hash(params, [:rev])
      pass_to_backend path
      return
    end

    # ACL(file): lookup via :rev / :linkrev is prevented now by backend if $nosharedtrees is set
    if request.put?
      path += build_query_from_hash(params, [:user, :comment, :rev, :linkrev, :keeplink, :meta])
      
      if  allowed
        # file validation where possible
        if params[:file] == "_link"
           validator = Suse::Validator.new( "link" )
           validator.validate(request)
        elsif params[:file] == "_aggregate"
           validator = Suse::Validator.new( "aggregate" )
           validator.validate(request)
        end

        if params[:file] == "_link"
          data = REXML::Document.new(request.raw_post.to_s)
          data.elements.each("link") do |e|
            tproject_name = e.attributes["project"]
            tpackage_name = e.attributes["package"]
            tprj = DbProject.find_by_name(tproject_name)
            if tprj.nil?
              # link to remote project ?
              unless tprj = DbProject.find_remote_project(tproject_name)
                render_error :status => 404, :errorcode => 'not_found',
                :message => "The given project #{tproject_name} does not exist"
                return
              end
            else
              tpkg = tprj.find_package(tpackage_name)
              if tpkg.nil?
                # check if this is a package on a remote OBS instance
                begin
                  answer = Suse::Backend.get("/source/#{URI.escape tproject_name}/#{URI.escape tpackage_name}/_meta")
                rescue
                  render_error :status => 404, :errorcode => 'not_found',
                  :message => "The given package #{tpackage_name} does not exist in project #{tproject_name}"
                  return
                end
              end
              
              # ACL(file): _link access behaves like project not existing
              if tpkg and tpkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(tpkg)
                render_error :status => 404, :errorcode => 'not_found',
                :message => "The given package #{tpackage_name} does not exist in project #{tproject_name}"
                return
              end

              # ACL(file): _link sourceaccess gives permisson denied
              if tpkg and tpkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(tpkg)
                render_error :status => 403, :errorcode => "source_access_no_permission",
                :message => "No permission to _link to package #{tpackage_name} at project #{tproject_name}"
                return
              end
            end
            logger.debug "_link checked against #{tpackage_name} in  #{tproject_name} package permission"
          end
        elsif params[:file] == "_aggregate"
          data = REXML::Document.new(request.raw_post.to_s)
          data.elements.each("aggregate") do |e|
            tproject_name = e.attributes["project"]
            tprj = DbProject.find_by_name(tproject_name)
            if tprj.nil?
              render_error :status => 404, :errorcode => 'not_found',
              :message => "The given #{tproject_name} does not exist"
              return
            end
            
            # ACL(file): _aggregate access behaves like project not existing
            if tprj.disabled_for?('access', nil, nil) and not @http_user.can_access?(tprj)
              render_error :status => 404, :errorcode => 'not_found',
              :message => "The given package #{tpackage_name} does not exist in project #{tproject_name}"
              return
            end

            # ACL(file): _aggregate binarydownload denies access to repositories
            if tprj.disabled_for?('binarydownload', nil, nil) and not @http_user.can_download_binaries?(tprj)
              render_error :status => 403, :errorcode => "download_binary_no_permission",
              :message => "No permission to _aggregate binaries from project #{params[:project]}"
              return
            end
            logger.debug "_aggregate checked against #{tproject_name} project permission"
          end
        end

        pass_to_backend path
        pack.update_timestamp
        if package_name == "_product"
          update_product_autopackages
        end
      else
        render_error :status => 403, :errorcode => 'put_file_no_permission',
          :message => "Insufficient permissions to store file in package #{package_name}, project #{project_name}"
      end
    elsif request.delete?
      path += build_query_from_hash(params, [:user, :comment, :rev, :linkrev, :keeplink])
      
      if  allowed
        Suse::Backend.delete path
        pack = DbPackage.find_by_project_and_name(project_name, package_name)
        pack.update_timestamp
        if package_name == "_product"
          update_product_autopackages
        end
        render_ok
      else
        render_error :status => 403, :errorcode => 'delete_file_no_permission',
          :message => "Insufficient permissions to delete file"
      end
    end
  end

  private

  # POST /source?cmd=branch
  def index_branch
    # set defaults
    unless params[:attribute]
      params[:attribute] = "OBS:Maintained"
    end
    unless params[:update_project_attribute]
      params[:update_project_attribute] = "OBS:UpdateProject"
    end
    unless params[:target_project]
      if params[:request]
        params[:target_project] = "home:#{@http_user.login}:branches:REQUEST_#{params[:request]}"
      else
        params[:target_project] = "home:#{@http_user.login}:branches:#{params[:attribute].gsub(':', '_')}"
        params[:target_project] += ":#{params[:package]}" if params[:package]
      end
    end

    tprj = DbProject.find_by_name(params[:target_project]) if params[:target_project]
    
    # ACL(index_branch): in case of access, project is really hidden and shown as non existing to users without access
    if tprj and tprj.disabled_for?('access', nil, nil) and not @http_user.can_access?(tprj)
      render_error :status => 404, :errorcode => 'not_found',
      :message => "Unknown project #{params[:target_project]}"
      return
    end

    # ACL(index_branch): sourceaccess gives permisson denied
    if tprj and tprj.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(tprj)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{@http_user.login} has no read access to project #{params[:target_project]}"
      return
    end

    # permission check
    unless @http_user.can_create_project?(params[:target_project])
      render_error :status => 403, :errorcode => "create_project_no_permission",
        :message => "no permission to create project '#{params[:target_project]}' while executing branch command"
      return
    end

    # find packages to be branched
    if params[:request]
      # find packages from request
      data = Suse::Backend.get("/request/#{params[:request]}").body
      req = BsRequest.new(data)

      @packages = []
      req.each_action do |action|
        prj=nil
        pkg=nil
        if action.has_element? 'source'
          if action.source.has_attribute? 'project'
            prj = DbProject.find_by_name action.source.project
            # ACL(index_branch): access behaves like project not existing
            if prj and prj.disabled_for?('access', nil, nil) and not @http_user.can_access?(prj)
              render_error :status => 404, :errorcode => 'not_found',
              :message => "The given project #{action.source.project} does not exist "
              return
            end

            # ACL(index_branch): source access gives permisson denied
            if prj and prj.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(prj)
              render_error :status => 403, :errorcode => "source_access_no_permission",
              :message => "user #{@http_user.login} has no read access to project #{action.source.project}"
              return
            end

            unless prj
              render_error :status => 404, :errorcode => 'unknown_project',
                :message => "Unknown source project #{action.source.project} in request #{params[:request]}"
              return
            end
          end
          if action.source.has_attribute? 'package'
            pkg = prj.db_packages.find_by_name action.source.package

            # ACL(index_branch): access behaves like project not existing
            if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
              render_error :status => 404, :errorcode => 'not_found',
              :message => "The given package #{package_name} does not exist in project #{project_name}"
              return
            end

            # ACL(index_branch): source access gives permisson denied
            if pkg and pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
              render_error :status => 403, :errorcode => "source_access_no_permission",
              :message => "user #{@http_user.login} has no read access to package #{action.source.package}, project #{action.source.project}"
              return
            end

            unless pkg
              render_error :status => 404, :errorcode => 'unknown_package',
                :message => "Unknown source package #{action.source.package} in project #{action.source.project} in request #{params[:request]}"
              return
            end
          end
        end

        @packages.push(pkg)
      end
    else
      # find packages via attributes
      at = AttribType.find_by_name(params[:attribute])
      if not at
        render_error :status => 403, :errorcode => 'not_found',
          :message => "The given attribute #{params[:attribute]} does not exist"
        return
      end
      if params[:value]
        @packages = DbPackage.find_by_attribute_type_and_value( at, params[:value], params[:package] )
      else
        @packages = DbPackage.find_by_attribute_type( at, params[:package] )
      end
    end

    unless @packages.length > 0
      render_error :status => 403, :errorcode => "not_found",
        :message => "no packages could get found"
      return
    end

    #create branch project
    oprj = DbProject.find_by_name params[:target_project]
    if oprj.nil?
      title = "Branch project for package #{params[:package]}"
      description = "This project was created for package #{params[:package]} via attribute #{params[:attribute]}"
      if params[:request]
        title = "Branch project based on request #{params[:request]}"
        description = "This project was created as a clone of request #{params[:request]}"
      end
      DbProject.transaction do
        oprj = DbProject.new :name => params[:target_project], :title => title, :description => description
        oprj.add_user @http_user, "maintainer"
        oprj.flags.create( :position => 1, :flag => 'build', :status => "disable" )
        oprj.store
      end
      if params[:request]
        ans = AttribNamespace.find_by_name "OBS"
        at = AttribType.find( :first, :joins => ans, :conditions=>{:name=>"RequestCloned"} )

        a = Attrib.new(:db_project => oprj, :attrib_type => at)
        a.values << AttribValue.new(:value => params[:request], :position => 1)
        a.save
      end
    else
      unless @http_user.can_modify_project?(oprj)
        render_error :status => 403, :errorcode => "modify_project_no_permission",
          :message => "no permission to modify project '#{params[:target_project]}' while executing branch by attribute command"
        return
      end
    end

    # create package branches
    # collect also the needed repositories here
    @packages.each do |p|
      # is a update project defined and a package there ?
      pac = p
      aname = params[:update_project_attribute]
      name_parts = aname.split(/:/)
      if name_parts.length != 2
        raise ArgumentError, "attribute '#{aname}' must be in the $NAMESPACE:$NAME style"
      end

      # find origin package to be branched
      branch_target_project = pac.db_project.name
      branch_target_package = pac.name

      btpkg=DbPackage.find_by_project_and_name(branch_target_project, branch_target_package) 

      # ACL(index_branch): access behaves like project not existing
      if btpkg and btpkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(btpkg)
        render_error :status => 404, :errorcode => 'not_found',
        :message => "The given package #{branch_target_package} does not exist in project #{branch_target_project}"
        return
      end

      # ACL(index_branch): source access gives permisson denied
      if btpkg and btpkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(btpkg)
        render_error :status => 403, :errorcode => "source_access_no_permission",
        :message => "user #{@http_user.login} has no read access to package #{branch_target_package}, project #{branch_target_project}"
        return
      end

      if not params[:request] and a = p.db_project.find_attribute(name_parts[0], name_parts[1]) and a.values[0]
        if pa = DbPackage.find_by_project_and_name( a.values[0].value, p.name )
          pac = pa
          branch_target_project = pac.db_project.name
          branch_target_package = pac.name
        else
          # package exists not yet in update project, but it may have a project link ?
    	  p = DbProject.find_by_name(a.values[0].value)
    	  if p and p.find_package( pac.name )
            branch_target_project = a.values[0].value
          end
        end
      end
      proj_name = pac.db_project.name.gsub(':', '_')
      pack_name = pac.name.gsub(':', '_')+"."+proj_name

      # create branch package
      # no find_package call here to check really this project only
      if opkg = oprj.db_packages.find_by_name(pack_name)
        render_error :status => 400, :errorcode => "double_branch_package",
          :message => "branch target package already exists: #{oprj.name}/#{opkg.name}"
        return
      else
        opkg = oprj.db_packages.new(:name => pack_name, :title => pac.title, :description => pac.description)
        oprj.db_packages << opkg
      end

      # create repositories, if missing
      pac.db_project.repositories.each do |repo|
        orepo = oprj.repositories.create :name => proj_name+"_"+repo.name
        orepo.architectures = repo.architectures
        orepo.path_elements.create(:link => repo, :position => 1)
      end

      opkg.store

      # branch sources in backend
      Suse::Backend.post "/source/#{oprj.name}/#{opkg.name}?cmd=branch&oproject=#{CGI.escape(branch_target_project)}&opackage=#{CGI.escape(branch_target_package)}", nil
    end

    # store project data in DB and XML
    oprj.store

    # all that worked ? :)
    render_ok :data => {:targetproject => params[:target_project]}
  end

  # create a id collection of all projects doing a project link to this one
  # POST /source/<project>?cmd=showlinked
  def index_project_showlinked
    valid_http_methods :post
    project_name = params[:project]

    # ACL(index_project_showlinked): check project itself for access, project is really hidden and shown as non existing to users without access
    tprj = DbProject.find_by_name(params[:project])
    if tprj and tprj.disabled_for?('access', nil, nil) and not @http_user.can_access?(tprj)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project #{params[:project]}"
      return
    end

    builder = FasterBuilder::XmlMarkup.new( :indent => 2 )
    pro = DbProject.find_by_name project_name
    xml = builder.collection() do |c|
      pro.find_linking_projects.each do |l|
        # ACL(index_project_showlinked): sort out access proteced projects as hidden
        unless pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
          p={}
          p[:name] = l.name
          c.project(p)
        end
      end
    end
    render :text => xml.target!, :content_type => "text/xml"
  end

  # POST /source/<project>?cmd=extendkey
  def index_project_extendkey
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]

    pro = DbProject.find_by_name project_name
    # ACL(index_project_extendkey): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    if pro and pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    pass_to_backend path
  end

  # POST /source/<project>?cmd=createkey
  def index_project_createkey
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]

    pro = DbProject.find_by_name project_name
    # ACL(index_project_createkey): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    # adrian: this should be checked anyway in index_project already
    if pro and pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    pass_to_backend path
  end

  # POST /source/<project>?cmd=undelete
  def index_project_undelete
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]

    pro = DbProject.find_by_name project_name
    # ACL(index_project_undelete): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    # ACL Adrian: this should have be checked anyway in index_project already
    if pro and pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    pass_to_backend path
  end

  # POST /source/<project>?cmd=createpatchinfo
  def index_project_createpatchinfo
    project_name = params[:project]

    pro = DbProject.find_by_name project_name
    # ACL(index_project_createpatchinfo): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    # adrian: this should be checked anyway in index_project already
    if pro and pro.disabled_for?('access', nil, nil) and not @http_user.can_access?(pro)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end

    name=""
    if params[:name]
      name=params[:name] if params[:name]
    end
    pkg_name = "_patchinfo:#{name.gsub(/\W/, '_')}"
    patchinfo_path = "#{request.path}/#{pkg_name}"

    # request binaries in project from backend
    binaries = list_all_binaries_in_path("/build/#{params[:project]}")

    if binaries.length < 1 and not params[:force]
      render_error :status => 400, :errorcode => "no_matched_binaries",
        :message => "No binary packages were found in project repositories"
      return
    end

    # FIXME: check for still building packages

    # create patchinfo package
    if not DbPackage.find_by_project_and_name( params[:project], pkg_name )
      prj = DbProject.find_by_name( params[:project] )
      pkg = DbPackage.new(:name => pkg_name, :title => "Patchinfo", :description => "Collected packages for update")
      prj.db_packages << pkg
      Package.find(pkg_name, :project => params[:project]).save
      if name==""
        name=pkg_name
      end
    else
      # shall we do a force check here ?
    end

    # create patchinfo XML file
    node = Builder::XmlMarkup.new(:indent=>2)
    xml = node.patchinfo(:name => name) do |n|
      binaries.each do |binary|
        node.binary(binary)
      end
      node.packager    @http_user.login
      node.bugzilla    ""
      node.swampid     ""
      node.category    ""
      node.rating      ""
      node.summary     ""
      node.description ""
      # FIXME add all bugnumbers from attributes
    end
    backend_put( patchinfo_path+"/_patchinfo?user="+@http_user.login+"&comment=generated%20file%20by%20frontend", xml )

    render_ok
  end

  def list_all_binaries_in_path path
    # ACL(list_all_binaries_in_path) TODO: check if this needs to be instrumented
    d = backend_get(path)
    data = REXML::Document.new(d)
    binaries = []

    data.elements.each("directory/entry") do |e|
      name = e.attributes["name"]
      list_all_binaries_in_path("#{path}/#{name}").each do |l|
        binaries.push( l )
      end
    end
    data.elements.each("binarylist/binary") do |b|
      name = b.attributes["filename"]
      # strip main name from binary
      # patchinfos are only designed for rpms so far
      binaries.push( name.sub(/-[^-]*-[^-]*.rpm$/, '' ) )
    end

    binaries.uniq!
    return binaries
  end

  # create a id collection of all packages doing a package source link to this one
  # POST /source/<project>/<package>?cmd=showlinked
  def index_package_showlinked
    valid_http_methods :post
    project_name = params[:project]
    package_name = params[:package]

    pack = DbPackage.find_by_project_and_name( project_name, package_name )
    # ACL(index_package_showlinked): in case of access, package is really hidden and shown as non existing to users without access
    if pack and pack.disabled_for?('access', nil, nil) and not @http_user.can_access?(pack)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    unless pack
      # package comes from remote instance

      # FIXME: return an empty list for now
      # we could request the links on remote instance via that: but we would need to search also localy and merge ...

#      path = "/search/package/id?match=(@linkinfo/package=\"#{CGI.escape(package_name)}\"+and+@linkinfo/project=\"#{CGI.escape(project_name)}\")"
#      answer = Suse::Backend.post path, nil
#      render :text => answer.body, :content_type => 'text/xml'
      render :text => "<collection/>", :content_type => 'text/xml'
      return
    end

    builder = FasterBuilder::XmlMarkup.new( :indent => 2 )
    xml = builder.collection() do |c|
      pack.find_linking_packages.each do |l|
        unless pack.disabled_for?('access', nil, nil) and not @http_user.can_access?(pack)
          p={}
          p[:project] = l.db_project.name
          p[:name] = l.name
          c.package(p)
        end
      end
    end
    render :text => xml.target!, :content_type => "text/xml"
  end

  # POST /source/<project>/<package>?cmd=undelete
  def index_package_undelete
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_undelete): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment])
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=createSpecFileTemplate
  def index_package_createSpecFileTemplate
    # ACL(index_package_createSpecFileTemplate) TODO: check if this needs access check
    specfile_path = "#{request.path}/#{params[:package]}.spec"
    begin
      backend_get( specfile_path )
      render_error :status => 400, :errorcode => "spec_file_exists",
        :message => "SPEC file already exists."
      return
    rescue ActiveXML::Transport::NotFoundError
      specfile = File.read "#{RAILS_ROOT}/files/specfiletemplate"
      backend_put( specfile_path, specfile )
    end
    render_ok
  end

  # POST /source/<project>/<package>?cmd=rebuild
  def index_package_rebuild
    project_name = params[:project]
    package_name = params[:package]
    repo_name = params[:repo]
    arch_name = params[:arch]

    p = DbProject.find_by_name(project_name)
    # ACL(index_package_rebuild): in case of access, project is really hidden and shown as non existing to users without access
    if p.nil? or (p.disabled_for?('access', repo_name, arch_name) and not @http_user.can_access?(p))
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{project_name}'"
      return
    end

    # check for sources in this or linked project
    pkg = p.find_package(package_name)
    unless pkg
      # check if this is a package on a remote OBS instance
      answer = Suse::Backend.get(request.path)
      unless answer
        render_error :status => 400, :errorcode => 'unknown_package',
          :message => "Unknown package '#{package_name}'"
        return
      end
    end

    path = "/build/#{project_name}?cmd=rebuild&package=#{package_name}"
    if repo_name
      if p.repositories.find_by_name(repo_name).nil?
        render_error :status => 400, :errorcode => 'unknown_repository',
          :message=> "Unknown repository '#{repo_name}'"
        return
      end
      path += "&repository=#{repo_name}"
    end
    if arch_name
      path += "&arch=#{arch_name}"
    end

    backend.direct_http( URI(path), :method => "POST", :data => "" )

    render_ok
  end

  # POST /source/<project>/<package>?cmd=commit
  def index_package_commit
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_commit): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_commit): sourceaccess gives permisson denied
    if pkg and pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{params[:package]}, project #{params[:project]}"
      return
    end

    # ACL(index_package_commit): lookup via :rev / :linkrev is prevented now by backend if $nosharedtrees is set
    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment, :rev, :linkrev, :keeplink, :repairlink])
    pass_to_backend path

    if params[:package] == "_product"
      update_product_autopackages
    end
  end

  # POST /source/<project>/<package>?cmd=commitfilelist
  def index_package_commitfilelist
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_commitfilelist): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_commitfilelist): sourceaccess gives permisson denied
    if pkg and pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{params[:package]}, project #{params[:project]}"
      return
    end

    # ACL(index_package_commitfilelist): lookup via :rev / :linkrev is prevented now by backend if $nosharedtrees is set
    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment, :rev, :linkrev, :keeplink, :repairlink])
    pass_to_backend path
    
    if params[:package] == "_product"
      update_product_autopackages
    end
  end

  # POST /source/<project>/<package>?cmd=diff
  def index_package_diff
    valid_http_methods :post
    project_name = params[:project]
    package_name = params[:package]
    oproject_name = params[:oproject]
    opackage_name = params[:opackage]
 
    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    oprj = DbProject.find_by_name(oproject_name)
    
    if oprj
      opackage_name = package_name if opackage_name.nil?
      opkg = oprj.find_package(opackage_name)
      
      # ACL(index_package_diff): in case of access, package is really hidden and shown as non existing to users without access
      if opkg and opkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(opkg)
        render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{params[:opackage]} in project #{params[:oproject]}"
        return
      end

      # ACL(index_package_diff): sourceaccess gives permisson denied
      if opkg and opkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(opkg)
        render_error :status => 403, :errorcode => "source_access_no_permission",
        :message => "user #{params[:user]} has no read access to package #{params[:opackage]}, project #{params[:oproject]}"
        return
      end
    end

    # ACL(index_package_diff): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_diff): sourceaccess gives permisson denied
    if pkg and pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{params[:package]}, project #{params[:project]}"
      return
    end

    # ACL(index_package_diff): lookup via :rev* / :linkrev* is prevented now by backend if $nosharedtrees is set
    path = request.path
    path << build_query_from_hash(params, [:cmd, :rev, :oproject, :opackage, :orev, :expand, :unified, :linkrev, :olinkrev, :missingok])
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=linkdiff
  def index_package_linkdiff
    valid_http_methods :post
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_linkdiff): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_linkdiff): sourceaccess gives permisson denied
    if pkg and pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{params[:package]}, project #{params[:project]}"
      return
    end

    # ACL(index_package_linkdiff): lookup via :rev / :linkrev is prevented now by backend if $nosharedtrees is set
    path = request.path
    path << build_query_from_hash(params, [:rev, :unified, :linkrev])
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=copy
  def index_package_copy
    valid_http_methods :post
    params[:user] = @http_user.login

    prj = DbProject.find_by_name(params[:project])
    pack = prj.find_package(params[:package])
    if pack.nil? 
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_copy): access behaves like package / project not existing
    if pack.disabled_for?('access', nil, nil) and not @http_user.can_access?(pack)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    # ACL(index_package_copy): source access gives permisson denied
    if pack.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pack)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{package_name}, project #{project_name}"
      return
    end

    # ACL(index_package_copy): lookup via :rev / :linkrev is prevented now by backend if $nosharedtrees is set
    # We need to use the project name of package object, since it might come via a project linked project
    path = "/source/#{pack.db_project.name}/#{pack.name}"
    path << build_query_from_hash(params, [:cmd, :rev, :user, :comment, :oproject, :opackage, :orev, :expand, :keeplink, :repairlink, :linkrev, :olinkrev, :requestid, :dontupdatesource])
    
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=runservice
  def index_package_runservice
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_runservice): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :comment])
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=deleteuploadrev
  def index_package_deleteuploadrev
    valid_http_methods :post
    params[:user] = @http_user.login
    project_name = params[:project]
    package_name = params[:package]

    prj = DbProject.find_by_name(project_name)
    pkg = prj.find_package(package_name)
    # ACL(index_package_deleteuploadrev): in case of access, package is really hidden and shown as non existing to users without access
    if pkg and pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd])
    pass_to_backend path
  end

  # POST /source/<project>/<package>?cmd=linktobranch
  def index_package_linktobranch
    valid_http_methods :post
    params[:user] = @http_user.login
    prj_name = params[:project]
    pkg_name = params[:package]
    pkg_rev = params[:rev]
    pkg_linkrev = params[:linkrev]

    prj = DbProject.find_by_name prj_name
    pkg = prj.db_packages.find_by_name(pkg_name)
    if pkg.nil?
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{pkg_name} in project #{prj_name}"
      return
    end

    # ACL(index_package_linktobranch): acces behaves like package / project not existing
    if pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{pkg_name} in project #{prj_name}"
      return
    end

    # ACL(index_package_linktobranch): source access gives permisson denied
    if pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{pkg_name} in project #{prj.name}"
      return
    end

    #convert link to branch
    rev = ""
    if not pkg_rev.nil? and not pkg_rev.empty?
      rev = "&orev=#{pkg_rev}"
    end
    linkrev = ""
    if not pkg_linkrev.nil? and not pkg_linkrev.empty?
      linkrev = "&linkrev=#{pkg_linkrev}"
    end
    Suse::Backend.post "/source/#{prj_name}/#{pkg_name}?cmd=linktobranch&user=#{CGI.escape(params[:user])}#{rev}#{linkrev}", nil

    render_ok
  end

  # POST /source/<project>/<package>?cmd=branch&target_project="optional_project"&target_package="optional_package"&update_project_attribute="alternative_attribute"&comment="message"
  def index_package_branch
    valid_http_methods :post
    params[:user] = @http_user.login
    prj_name = params[:project]
    pkg_name = params[:package]
    pkg_rev = params[:rev]
    target_project = params[:target_project]
    target_package = params[:target_package]
    if not params[:update_project_attribute]
      params[:update_project_attribute] = "OBS:UpdateProject"
    end
    logger.debug "branch call of #{prj_name} #{pkg_name}"

    prj = DbProject.find_by_name prj_name
    if prj.nil?
      render_error :status => 404, :errorcode => 'unknown_project',
        :message => "Unknown project #{prj_name}"
      return
    end
    pkg = prj.find_package( pkg_name )
    if pkg.nil?
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{pkg_name} in project #{prj.name}"
      return
    end

    # ACL(index_package_branch): acces behaves like project not existing
    if pkg.disabled_for?('access', nil, nil) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => 'unknown_package',
      :message => "Unknown package #{pkg_name} in project #{prj.name}"
      return
    end

    # ACL(index_package_branch): source access gives permisson denied
    if pkg.disabled_for?('sourceaccess', nil, nil) and not @http_user.can_source_access?(pkg)
      render_error :status => 403, :errorcode => "source_access_no_permission",
      :message => "user #{params[:user]} has no read access to package #{pkg_name} in project #{prj.name}"
      return
    end

    # is a update project defined and a package there ?
    aname = params[:update_project_attribute]
    name_parts = aname.split(/:/)
    if name_parts.length != 2
      raise ArgumentError, "attribute '#{aname}' must be in the $NAMESPACE:$NAME style"
    end

    if a = prj.find_attribute(name_parts[0], name_parts[1]) and a.values[0]
      if pa = DbPackage.find_by_project_and_name( a.values[0].value, pkg.name )
        # We have a package in the update project already, take that
        pkg = pa
        prj = pkg.db_project
    	logger.debug "branch call found package in update project #{prj.name}"
      else
        update_prj = DbProject.find_by_name( a.values[0].value )
        update_pkg = update_prj.find_package( pkg.name )
        if update_pkg
          # We have no package in the update project yet, but sources are reachable via project link
          pkg = update_pkg
          prj = update_prj
        end
      end
    end

    # validate and resolve devel package or devel project definitions
    if not params[:ignoredevel] and ( pkg.develproject or pkg.develpackage )
      pkg = pkg.resolve_devel_package
      prj = pkg.db_project
      logger.debug "devel project is #{prj.name} #{pkg.name}"
    end

    # link against srcmd5 instead of plain revision
    unless pkg_rev.nil?
      begin
        dir = Directory.find({ :project => params[:project], :package => params[:package], :rev => params[:rev]})
      rescue
        render_error :status => 400, :errorcode => 'invalid_filelist',
          :message => "no such revision"
        return
      end
      if dir.has_attribute? 'srcmd5'
        pkg_rev = dir.srcmd5
      else
        render_error :status => 400, :errorcode => 'invalid_filelist',
          :message => "no srcmd5 revision found"
        return
      end
    end
 
    oprj_name = "home:#{@http_user.login}:branches:#{prj.name}"
    opkg_name = pkg.name
    oprj_name = target_project unless target_project.nil?
    opkg_name = target_package unless target_package.nil?

    #create branch container
    oprj = DbProject.find_by_name oprj_name
    if oprj.nil?
      unless @http_user.can_create_project?(oprj_name)
        render_error :status => 403, :errorcode => "create_project_no_permission",
          :message => "no permission to create project '#{oprj_name}' while executing branch command"
        return
      end

      DbProject.transaction do
        oprj = DbProject.new :name => oprj_name, :title => "Branch of #{prj.title}", :description => prj.description
        oprj.add_user @http_user, "maintainer"
        oprj.flags.create( :status => "disable", :flag => 'publish')
        prj.repositories.each do |repo|
          orepo = oprj.repositories.create :name => repo.name
          orepo.architectures = repo.architectures
          orepo.path_elements << PathElement.new(:link => repo, :position => 1)
        end
        oprj.store
      end
    end

    #create branch package
    if opkg = oprj.db_packages.find_by_name(opkg_name)
      if params[:force]
        # shall we clean all files here ?
      else
        render_error :status => 400, :errorcode => "double_branch_package",
          :message => "branch target package already exists: #{oprj_name}/#{opkg_name}"
        return
      end

      unless @http_user.can_modify_package?(opkg)
        render_error :status => 403, :errorcode => "create_package_no_permission",
          :message => "no permission to create package '#{opkg_name}' for project '#{oprj_name}' while executing branch command"
        return
      end
    else
      unless @http_user.can_create_package_in?(oprj)
        render_error :status => 403, :errorcode => "create_package_no_permission",
          :message => "no permission to create package '#{opkg_name}' for project '#{oprj_name}' while executing branch command"
        return
      end

      opkg = oprj.db_packages.create(:name => opkg_name, :title => pkg.title, :description => params.has_key?(:comment) ? params[:comment] : pkg.description)
      opkg.add_user @http_user, "maintainer"
      opkg.store
    end

    #create branch of sources in backend
    rev = ""
    if not pkg_rev.nil? and not pkg_rev.empty?
      rev = "&orev=#{pkg_rev}"
    end
    comment = params.has_key?(:comment) ? "&comment=#{CGI.escape(params[:comment])}" : ""
    Suse::Backend.post "/source/#{oprj_name}/#{opkg_name}?cmd=branch&oproject=#{CGI.escape(prj.name)}&opackage=#{CGI.escape(pkg.name)}#{rev}&user=#{CGI.escape(@http_user.login)}#{comment}", nil

    render_ok :data => {:targetproject => oprj_name, :targetpackage => opkg_name, :sourceproject => prj.name, :sourcepackage => pkg.name}
  end

  # POST /source/<project>/<package>?cmd=set_flag&repository=:opt&arch=:opt&flag=flag&status=status
  def index_package_set_flag
    valid_http_methods :post

    required_parameters :project, :package, :flag, :status

    prj_name = params[:project]
    pkg_name = params[:package]

    # we can savely assume it exists - this function is called through dispatch_command
    prj = DbProject.find_by_name prj_name
    pkg = prj.find_package( pkg_name )
    if pkg.nil?
      render_error :status => 404, :errorcode => "unknown_package",
        :message => "Unknown package '#{pkg_name}' in project '#{prj_name}'"
      return
    end

    # ACL(index_package_set_flag): acces behaves like project not existing
    if pkg.disabled_for?('access', params[:repository], params[:arch]) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => "unknown_package",
      :message => "Unknown package '#{pkg_name}' in project '#{prj_name}'"
      return
    end

    # first remove former flags of the same class
    begin
      pkg.remove_flag(params[:flag], params[:repository], params[:arch])
      pkg.add_flag(params[:flag], params[:status], params[:repository], params[:arch])
    rescue ArgumentError => e
      render_error :status => 400, :errorcode => 'invalid_flag', :message => e.message
      return
    end
    pkg.store
    render_ok
  end

  # POST /source/<project>?cmd=set_flag&repository=:opt&arch=:opt&flag=flag&status=status
  def index_project_set_flag
    valid_http_methods :post

    required_parameters :project, :flag, :status

    prj_name = params[:project]

    prj = DbProject.find_by_name prj_name
    if prj.nil?
      render_error :status => 404, :errorcode => "unknown_project",
        :message => "Unknown project '#{prj_name}'"
      return
    end

    begin
      # first remove former flags of the same class
      prj.remove_flag(params[:flag], params[:repository], params[:arch])
      prj.add_flag(params[:flag], params[:status], params[:repository], params[:arch])
    rescue ArgumentError => e
      render_error :status => 400, :errorcode => 'invalid_flag', :message => e.message
      return
    end
      
    # ACL(index_project_set_flag): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    if prj and prj.disabled_for?('access', params[:repository], params[:arch]) and not @http_user.can_access?(prj)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{prj_name}'"
      return
    end

    prj.store
    render_ok
  end

  # POST /source/<project>/<package>?cmd=remove_flag&repository=:opt&arch=:opt&flag=flag
  def index_package_remove_flag
    valid_http_methods :post

    required_parameters :project, :package, :flag
    
    prj_name = params[:project]
    pkg_name = params[:package]

    # we can savely assume it exists - this function is called through dispatch_command
    prj = DbProject.find_by_name prj_name
    pkg = prj.find_package( pkg_name )
    if pkg.nil?
      render_error :status => 404, :errorcode => "unknown_package",
        :message => "Unknown package '#{pkg_name}' in project '#{prj_name}'"
      return
    end

    # ACL(index_package_remove_flag): acces behaves like project not existing
    if pkg.disabled_for?('access', params[:repository], params[:arch]) and not @http_user.can_access?(pkg)
      render_error :status => 404, :errorcode => "unknown_package",
        :message => "Unknown package '#{pkg_name}' in project '#{prj_name}'"
      return
    end
    pkg.remove_flag(params[:flag], params[:repository], params[:arch])
    pkg.store
    render_ok
  end

  # POST /source/<project>?cmd=remove_flag&repository=:opt&arch=:opt&flag=flag
  def index_project_remove_flag
    valid_http_methods :post
    required_parameters :project, :flag

    prj_name = params[:project]

    prj = DbProject.find_by_name prj_name
    if prj.nil?
      render_error :status => 404, :errorcode => "unknown_project",
        :message => "Unknown project '#{prj_name}'"
      return
    end

    # ACL(index_project_remove_flag): in case of access, project is really hidden, e.g. does not get listed, accessing says project is not existing
    if prj and prj.disabled_for?('access', params[:repository], params[:arch]) and not @http_user.can_access?(prj)
      render_error :status => 404, :errorcode => 'unknown_project',
      :message => "Unknown project '#{prj_name}'"
      return
    end

    prj.remove_flag(params[:flag], params[:repository], params[:arch])
    prj.store
    render_ok
  end

  def valid_project_name? name
    name =~ /^\w[-_+\w\.:]*$/
  end

  def valid_package_name? name
    return true if name == "_pattern"
    return true if name == "_project"
    return true if name == "_product"
    return true if name =~ /^_product:[-_+\w\.:]*$/
    name =~ /^\w[-_+\w\.:]*$/
  end

end
