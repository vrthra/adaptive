require 'webrick' 
require 'webrick/httpproxy' 
require 'optparse'

#puts req.request_line, req.raw_header
module WEBrick
  class RLProxyServer < WEBrick::HTTPProxyServer
    def initialize(hash)
      p hash
      @orig_parent = hash[:Parent]
      p @orig_parent
      super(hash)
    end
    def proxy_service(req, res)
      p req.request_uri
      case req.request_uri.to_s
      when /.*google.com.*/
        @parent = @orig_parent
        @config[:ProxyURI] = proxy_uri(req,res)
        puts "Using parent 8080"
      else
        @parent = nil
        @config[:ProxyURI] = proxy_uri(req,res)
        puts "Not using parent 8080"
      end
      super(req, res)
    end
    def cache(req, res)
      res.header['content-type'] = 'text/plain'
      res.body = 'cached output'
    end
    def proxy_uri(req, res)
      if @parent.nil?
        return nil 
      else
        uri = URI.parse(@parent)
        p uri
        return uri
      end
    end
  end
end


class ProxyServer 
    def handler(req, res) 
      puts req.request_line, req.raw_header
    end 
    def initialize(port, parent)
        @server = WEBrick::RLProxyServer.new( 
            :BindAddress    => '0.0.0.0', 
            :Port           => port, 
            :ProxyVia       => true, 
            #:ProxyContentHandler => method(:handler),
            :Parent => parent.nil? ? nil : parent
        )
    end 
    def start 
        @server.start 
    end 
    def stop 
        @server.shutdown 
    end 
end 

$next = nil
OptionParser.new do |o|
  o.on('-p PORT') {|b| $port = b.to_i }
  o.on('-n PROXY') {|b| $next = b}
  o.parse!
end


s = ProxyServer.new($port,$next)
%w[INT HUP].each do |sig|
  trap(sig) { s.stop } 
end
s.start

