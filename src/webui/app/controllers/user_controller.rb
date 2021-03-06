class UserController < ApplicationController
require 'opensuse/frontend'
  skip_before_filter :authorize, :transmit_credentials
  
  def login

  end
  
  def store_login
    login = @params [:user_login ]
    passwd = @params[:user_password]

    session[:login] = login
    session[:passwd] = passwd
  
    if passwd 
      logger.debug "#{login} wants to log in with pwd XXX"
    else 
      logger.debug "#{login} wants to log in with empty passwd"
    end
    
    # render_text "Alles OK: #{session[:login]}"
    redirect_back_or_default
  end

  def logout
    logger.debug "Login in Session is #{session[:login]}"
    session[:login] = nil
    session[:passwd] = nil
  end

  # store current uri in  the session.
  # we can return to this location by calling return_location
  def store_location
    session[:return_to] = @request.request_uri
  end

  # move to the last store_location call or to the passed default one
  def redirect_back_or_default(default = nil)
    if !default  
      default = url_for :controller => ''
    end
    logger.debug "Default url = #{default}"
    if session[:return_to].nil?
      redirect_to default
    else
      redirect_to_url session[:return_to]
      session[:return_to] = nil
    end
  end

  def edit
    @user = Person.find :login => session[:login]
    session[:user] = @user
  end

  def save
    @user = session[:user]

    @user.realname.data.text = params[:realname]
    @user.source_backend.host.data.text = params[:source_host]
    @user.source_backend.port.data.text = params[:source_port]
    @user.rpm_backend.host.data.text = params[:rpm_host]
    @user.rpm_backend.port.data.text = params[:rpm_port]

    if @user.save
      flash[:note] = "User data for user '#{@user.login}' successfully saved."
    else
      flash[:note] = "Failed to save user data for user '#{user.login}'."
    end

    session[:user] = nil

    redirect_to :controller => "home"
  end

  def newaccount
  
  end
end
