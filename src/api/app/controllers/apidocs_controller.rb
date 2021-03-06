class ApidocsController < ApplicationController

  @@apidocsbase = File.expand_path(APIDOCS_LOCATION)+"/"

  def index
    logger.debug "PATH: #{request.path}"
    if ( request.path !~ /\/$/ )
      redirect_to "/apidocs/"
    else
      filename = @@apidocsbase + "index.html"
      if ( !File.exist?( filename ) )
        render_text "Error"
      else
        render( :file => filename, :layout => "html" )
      end
    end
  end

  def method_missing symbol, *args
    file = symbol.id2name
    if ( file =~ /\.(xml|xsd)$/ )
      send_file( @@apidocsbase + file, :type => "text/xml",
        :disposition => "inline" )
    else
      super symbol, *args
    end
  end

end
