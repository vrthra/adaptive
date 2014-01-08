#!/usr/bin/ruby
srand(Time.now.to_i)

# for simplicity, I assume that each proxy only has parents and ignores peers.

# the state is represented as 
# (proxy_server, request.domain)
# we map the URL space to just domain space under the assumption that if a 
# proxy is good enough for a domain, then it is good enough for a URL.
LEVEL_CONST=100

$g_max_lvl = ARGV[0].to_i
$g_max_width = ARGV[1].to_i
$g_degree = ARGV[2].to_i

puts "level = #{$g_max_lvl}"
puts "width = #{$g_max_width}"
puts "degree = #{$g_degree}"

def max_level()
    #return 10
    return $g_max_lvl
end

def max_width()
    #return 10
    return $g_max_width
end

def get_degree()
    #return 2
    return $g_degree
end


class Cache
  def max_size
    return @_max_size
  end

  def initialize(max_size = 4)
    @_data = {}
    @_max_size = max_size
  end

  def store(key, value)
    @_data.store(key, [0, value])
    age_keys
    prune
  end

  def read(key)
    if value = @_data[key]
      renew(key)
      age_keys
      return value[1]
    end
    return nil
  end

  def renew(key)
    @_data[key][0] = 0
  end

  def delete_oldest
    m = @_data.values.map{ |v| v[0] }.max
    @_data.reject!{ |k,v| v[0] == m }
  end

  def age_keys
    @_data.each{ |k,v| @_data[k][0] += 1 }
  end

  def prune
    delete_oldest if @_data.size > @_max_size
  end
end

class Request
  def initialize(url)
    @_url = url
    case url
    when /http:\/\/([a-z0-9:]+)\/(.*)$/
      @_domain = $1;
      @_page = $2;
    end
  end
  def domain
    return @_domain
  end
  def page
    return @_page
  end
  def header
    return nil
  end
  def url
    return @_url
  end
end

class Response
  def initialize(domain, url, content, header, status)
    @_page = {:domain => domain, :url => url, :content => content, :header => header}
    @_status = status
  end
  def to_s
    return @_page[:url]
  end
  def set_reward(r)
    @_page[:header][:QReward] = r.to_s
  end
  def get_reward()
    return @_page[:header][:QReward].to_i
  end
  def get_q_header()
    return @_page[:header][:Q]
  end
  def set_q(value)
    @_page[:header][:Q] = value
  end
  def status
    return @_status
  end
end

class HTTPServer
  def domain
    return @_domain
  end
  def initialize(domain, pages)
    @_domain = domain
    @_page = {}
    pages.each do |path|
      @_page[path] = Response.new(domain,path,"< A page from #{domain}/#{p} >",{}, 200)
    end
  end
  def get(path)
    return @_page[path]
  end
end

class Reward
  def initialize(proxy)
    @_proxy = proxy
  end
  def get_reward(status)
    # if we are not the end point, just return -1 * load
    # if we are, then return (100 - load)
    case status
    when :MidWay
      return -1 * @_proxy.load
    when :EndPoint
      return 1000
    when :CacheHit
      return 1000
    when :NoService
      return -1000
    end
  end
end

class Q
  def initialize(parents)
    @_q = {}
    @_parents = parents
  end

  def get_q(s_url_domain,a_parent)
    key = to_key(s_url_domain,a_parent)
    @_q[key] = 0 if @_q[key].nil?
    return @_q[key]
  end
  def put_q(s_url_domain, a_parent, value)
    key = to_key(s_url_domain,a_parent)
    @_q[key] = value
  end

  def max_a(s_url_domain)
     # best next server for this state.
     srv = @_parents[0]
     max = get_q(s_url_domain, srv)
     @_parents.each do |a_p|
       q = get_q(s_url_domain, a_p)
       if q > max
         max = q
         srv = a_p
       end
     end
     return srv
  end

  def to_key(s_url_domain, a_parent)
    return 'url[' + s_url_domain + ']: parent[' + a_parent.to_s + ']'
  end
end

class Policy
  def initialize(proxy, q)
    @_proxy = proxy;
  end
  def next(req)
    # greedy. Just return the first policy found.
    return $topology[@_proxy.name][:next][0]
  end
  def update(domain,proxy,last_max_q, reward) 
  end
  def max_a_val(domain)
    return 0
  end
end

class QPolicy
  def initialize(proxy,q)
    @_proxy = proxy
    @_alpha = 0.1
    @_beta = 1.0
    # our q value estimate may be based on 
    # the load of the server
    # if the url is in the cache
    # or the cache hit ratio
    # RAM available
    # uptime

    # Action is the next server to choose from
    @_q = q
    @_t = 0
  end
  def q
    return @_q
  end
  def next(req)
    #GLIE
    @_t += 1
    s = rand(@_t) + 1
    if s == 1
      len = $topology[@_proxy.name][:next].length
      s = rand(len)
      $path << '*'
      return $topology[@_proxy.name][:next][s]
    else
      proxy = @_q.max_a(req.domain)
      return proxy
    end
  end

  def max_a_val(s_url_domain)
    a_parent = @_q.max_a(s_url_domain)
    val = @_q.get_q(s_url_domain, a_parent)
    return val
  end

  def update(s_url_domain, a_parent, last_max_q, reward)
    # Q(a,s)  = (1-alpha)*Q(a,s) + alpha(R(s) + beta*max_a(Q(a_,s_)))
    # the a is self here.
    q_now = @_q.get_q(s_url_domain, a_parent)
    q_new = (1 - @_alpha) * q_now + @_alpha*(reward + @_beta*last_max_q)
    @_q.put_q(s_url_domain, a_parent, q_new)
  end
end


# each proxy node maintains its own q(s,a) value
# each proxy is able to reach a fixed set of domains. for others, it has to
# rely on parents.
class ProxyNode
  def initialize(name, domains, parents)
    @_name = name 
    @_load = $topology[name][:load]
    @_parents = parents
    @_domains = domains
    @_q = Q.new(parents)
    @_policy = QPolicy.new(self, @_q)
    @_reward = Reward.new(self)
    @_cache = Cache.new(4)
  end
  def policy
    return @_policy
  end
  def load
    case rand(2)
    when 0
      @_load += 1
    else
      @_load -= 1
    end
    if @_load <0
      @_load = 0
    end
    return @_load
  end
  def name
    return @_name
  end
  # use this proxy to send request.
  # it returns back a hashmap that contains the body of response 
  # and a few headers.
  def request(req)
    # if the load is too high, decline the request.
    if @_load >= 100
      # reset the load now because after denying the requests the load
      # should be lower.
      @_load = rand(100)+1
      res = Response.new(req.domain,req.url,'Can not service',
                         {:last_proxy => @_name}, 501)
      reward = @_reward.get_reward(:NoService)
      res.set_reward(reward)
      $reward << reward
      return res
    end
    #puts "req at #{@_name}"
    s = @_cache.read(req.url)
    if not(s.nil?)
      $path << @_name.to_s
      $path << "+"
      reward = @_reward.get_reward(:CacheHit)
      s.set_reward(reward)
      $reward << reward
      return s
    end
    res = _request(req)
    @_cache.store(req.url,res) if res.status == 200
    return res
  end
  def _request(req)
    res = nil
    $path << @_name.to_s
    @_domains.each do |dom|
      if req.domain().to_i == dom
        res = fetch(req)
        reward = @_reward.get_reward(:EndPoint)
        res.set_reward(reward)
        $reward << reward
        return res
      end
    end
    if @_name < LEVEL_CONST*2
      res = Response.new(req.domain,req.url,'Can not service',
                         {:last_proxy => @_name}, 501)
      reward = @_reward.get_reward(:NoService)
      res.set_reward(reward)
      $reward << reward
      return res
    else
      res = forward(req)
      reward = @_reward.get_reward(:MidWay)
      res.set_reward(reward)
      $reward << reward
      return res
    end
  end

  def fetch(req)
    res = $server[req.domain.to_i].get(req.page)
    return res
  end
  def forward(req)
    #puts "req at #{@_name}"
    proxy = @_policy.next(req)
    res =  proxy_db(proxy).request(req)
    # updaate q
    last_max_q = res.get_q_header().to_i

    reward = res.get_reward()
    @_policy.update(req.domain,proxy,last_max_q, reward)
   
    # find the q value for the next best server for domain 
    next_q = @_policy.max_a_val(req.domain)
    res.set_q(next_q)
    return res
  end
end

$topology = {}
def proxy_db(p)
  # lookup and return proxy server.
  $proxydb = {} if $proxydb.nil?
  if $proxydb[p].nil?
    if p < LEVEL_CONST*2
      domains = $topology[p][:next]
      parents = []
    else
      domains = []
      parents = $topology[p][:next]
    end
    proxy = ProxyNode.new(p, domains, parents)
    $proxydb[p] = proxy
  end
  return $proxydb[p]
end

class Network
  def parents(p,l,w,levels,width)
    num_parents = get_degree()
    direct = p - LEVEL_CONST  # direct parent.
    parents = [direct]
    (1..num_parents).each do
      another = (w + rand(num_parents)) % width +1 + (l-1)*LEVEL_CONST
      parents << another
    end
    return parents.sort.uniq
  end
  def initialize()
    # construct the initial topology
    $server = {}
    (1..10).each do |i|
      s = i.to_s
      pages = []
      (1..10).each do |page|
        pages << "path-#{page.to_s}/page.html"
      end
      $server[i] = HTTPServer.new("domain#{s}.com", pages)
    end
    #@_user_proxy = initial_proxies
    # Links
    l = {}

    levels = max_level()
    width = max_width()
  
    (1..levels).each do |lvl|
      (1..width).each do |w|
        p = lvl*LEVEL_CONST + w
        par =  parents(p,lvl,w,levels,width)
        # puts "p = #{p} par=#{par.join(',')}"
        l[p] = par
      end
    end


#    l[11] = [1,2,3,4]
#    l[12] = [3,4,5,6]
#    l[13] = [5,6,7]
#    l[14] = [7,8,9,10]
#
#    l[21] = [11,12]
#    l[22] = [11,12,13]
#    l[23] = [12,13,14]
#    l[24] = [13,14]
#
#    l[31] = [21,22,23]
#    l[32] = [22,23]
#    l[33] = [22,23,24]
#    l[34] = [23,24]
#
#    l[41] = [31,32]
#    l[42] = [31,32,33]
#    l[43] = [32,33]
#    l[44] = [33,34]
#
#    l[51] = [41,42,43]
#    l[52] = [42,43]
#    l[53] = [43,44]
#    l[54] = [44]
#
#    l[61] = [51,53]
#    l[62] = [52,53]
#    l[63] = [53,54]
#    l[64] = [54,53]
#
#    l[71] = [61,63]
#    l[72] = [62,63,61]
#    l[73] = [63,54]
#    l[74] = [64]
#
#    l[81] = [71,72,73]
#    l[82] = [72,73]
#    l[83] = [73,74]
#    l[84] = [74]
#
#    l[91] = [81]
#    l[92] = [82,83]
#    l[93] = [83,84]
#    l[94] = [84,82,83]
#
#    l[101] = [91]
#    l[102] = [92,93]
#    l[103] = [93,94]
#    l[104] = [94,92,93]




    $topology = init_loads(l)
  end
  def init_loads(links)
    network = {}
    parents = 0
    count = 0
    links.keys.each do |l|
      parents += links[l].length
      count += 1
      network[l] = {:next =>links[l], :load =>load()}
    end
    puts "=================================="
    puts "degree = #{parents}/#{count} = #{(parents * 1.0)/(count * 1.0) }"
    return network
  end
  def load
    return rand(100)+1
  end

  def user_req(req)
    #---------------------------------------
    # Modify here for first level proxy
    # get our first level proxy. Here it is 10X
    #---------------------------------------
    proxy = max_level()*LEVEL_CONST + (rand(max_width())+1)
    #puts "req starting at #{proxy} for #{req.domain}"
    #p req.url
    res = proxy_db(proxy).request(req)
    return res
  end
  def show_loads
    (1..4).each do |layer|
      (1..4).each do |proxy|
        n = layer*10 + proxy
        print " " + n.to_s+"(" + $topology[n][:load].to_s + ")"
      end
      puts ""
    end
  end
  def show_max(domain)
    (1..4).each do |layer|
      l = layer*10
      (1..4).each do |proxy|
        p = proxy_db(proxy + l)
        x = p.policy.q.max_a(domain.to_s)
        print " " + p.name.to_s+" (" + x.to_s + ")"
      end
      puts ""
    end
  end
end

$path = []
$reward = []
n = Network.new
iter_total = 100
max_count = 0
(1..iter_total).each do |i|
  count = 0
  total = 100
  (1..total).each do |j|
    page = "path-#{rand(10)+1}/page.html"
    server = rand(10) + 1
    req = Request.new("http://" + server.to_s + '/' + page)
    res = n.user_req(req)
    trejectory = $path.map{|j| j+'>'}.join + (res.status == 200 ? "*" : "X") + "  " + req.domain
    #puts trejectory
    reward = $reward.map{|j| j.to_s+' '}.join
    total_reward = $reward.inject(0){|sum,x| sum+x}
    #puts "reward:(#{total_reward}) #{reward}" 
    $path = []
    $reward = []
    if res.status > 500
      count += 1
    end
  end
  puts "#{count}/#{total}"
  #puts "Loads:"
  #puts "---------------#{i}"
  max_count = i
  break if count == 0
  #n.show_loads
  #(1..10).each do |i|
  #  puts "MaxAVal: " + i.to_s
  #  puts "---------------"
  #  n.show_max(i)
  #end
end
puts "maxcount: #{max_count}"
