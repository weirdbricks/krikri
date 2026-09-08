require "json"

# Crystal port of the `ansible.utils` ipaddr filter family (ipaddr,
# ipwrap, ipv4, ipv6, ipsubnet, ipmath, next_nth_usable,
# previous_nth_usable, network_in_network, network_in_usable, ip4_hex),
# mirrored against real ansible-core 2.19.4 + ansible.utils + netaddr
# 1.3.0 live (every query probed against real ansible-playbook on this
# host - see the specs in spec/unit/ipaddr_spec.cr). Operates on
# JSON::Any so both the hand-rolled FilterEngine and the Crinja
# registration in jinja_filters.cr can share one implementation.
#
# The query dispatch mirrors the installed collection's own
# `ipaddr_utils.ipaddr()` query_func_map exactly - including the
# queries that map does NOT have ('addr', 'bin', 'hex', 'reserved',
# 'unspecified', 'host-prefixed', 'netprefix' all fail with real
# Ansible's own "unknown filter type" error on ansible-core 2.19.4 /
# ansible.utils, verified live, so they fail here too rather than being
# "helpfully" implemented as aliases the real plugin does not have).
#
# One deliberate normalization: the real plugin's falsy results come
# back as a mix of Python `False` and `None` (query-dependent); both
# are truthiness-identical, so both surface here as JSON `false`.
module Krikri
  module IpAddrCore
    extend self

    class IpError < Exception
    end

    FAMILY_FILTERS = Set{
      "ipaddr", "ipwrap", "ipv4", "ipv6", "ipsubnet", "ipmath",
      "next_nth_usable", "previous_nth_usable", "network_in_network",
      "network_in_usable", "ip4_hex",
    }

    private struct Net
      getter version : Int32
      getter ip : UInt128
      getter prefixlen : Int32
      getter vtype : String

      def initialize(@version : Int32, @ip : UInt128, @prefixlen : Int32, @vtype : String)
      end

      def width : Int32
        version == 4 ? 32 : 128
      end

      def max_int : UInt128
        version == 4 ? 0xFFFFFFFF_u128 : UInt128::MAX
      end

      def hostmask : UInt128
        return max_int if prefixlen == 0
        return 0_u128 if prefixlen >= width
        (1_u128 << (width - prefixlen)) - 1
      end

      def netmask : UInt128
        max_int - hostmask
      end

      def network : UInt128
        ip & netmask
      end

      def broadcast : UInt128
        network | hostmask
      end

      def size : UInt128?
        return nil if version == 6 && prefixlen == 0
        1_u128 << (width - prefixlen)
      end

      def first_usable : UInt128?
        sz = size || return nil
        return nil if sz == 1
        sz == 2 ? network : network + 1
      end

      def last_usable : UInt128?
        sz = size || return nil
        return nil if sz == 1
        sz == 2 ? broadcast : broadcast - 1
      end

      def loopback? : Bool
        version == 4 ? (ip >> 24) == 127 : ip == 1
      end

      def multicast? : Bool
        version == 4 ? (ip >> 28) == 0xE : (ip >> 120) == 0xFF
      end

      def unicast? : Bool
        !multicast?
      end

      def link_local? : Bool
        version == 4 ? (ip >> 16) == 0xA9FE : (ip >> 118) == 0x3FA
      end

      def global? : Bool
        if version == 4
          V4_NON_GLOBAL.none? { |range| range[0] <= ip <= range[1] }
        else
          V6_NON_GLOBAL.none? do |prefix, len|
            mask = len == 0 ? 0_u128 : len >= 128 ? UInt128::MAX : ~((1_u128 << (128 - len)) - 1)
            (ip & mask) == prefix
          end
        end
      end

      def netmask_pattern? : Bool
        return false if ip == 0
        trailing_zeros(ip) + ip.popcount == width
      end

      def hostmask_pattern? : Bool
        inv = ~ip & max_int
        return false if inv == 0
        trailing_zeros(inv) + inv.popcount == width
      end

      def trailing_zeros(n : UInt128) : Int32
        return width if n == 0
        count = 0
        m = n
        while m & 1 == 0
          count += 1
          m >>= 1
        end
        count
      end

      # the "type" query's own answer for this net - a /32-or-/128
      # network ('192.168.0.1/32') is an ADDRESS per _type_query's
      # size==1 branch, which ipsubnet's branches key on (real code
      # recomputes vtype from the normalized value, not from the
      # original parse)
      def type_query : String
        if size.try(&.==(1)) || ip != network
          "address"
        else
          "network"
        end
      end
    end

    # IANA special-purpose ranges netaddr 1.3.0's IPAddress.is_global()
    # treats as non-global (probed live: 224.0.0.0/4 multicast and
    # 192.88.99.0/24 ARE global there; everything below is not).
    private V4_NON_GLOBAL = [
      {0x00000000_u128, 0x00FFFFFF_u128},
      {0x0A000000_u128, 0x0AFFFFFF_u128},
      {0x64400000_u128, 0x647FFFFF_u128},
      {0x7F000000_u128, 0x7FFFFFFF_u128},
      {0xA9FE0000_u128, 0xA9FEFFFF_u128},
      {0xAC100000_u128, 0xAC1FFFFF_u128},
      {0xC0000000_u128, 0xC00000FF_u128},
      {0xC0000200_u128, 0xC00002FF_u128},
      {0xC0A80000_u128, 0xC0A8FFFF_u128},
      {0xC6120000_u128, 0xC613FFFF_u128},
      {0xC6336400_u128, 0xC63364FF_u128},
      {0xCB007100_u128, 0xCB0071FF_u128},
      {0xF0000000_u128, 0xFFFFFFFE_u128},
      {0xFFFFFFFF_u128, 0xFFFFFFFF_u128},
    ]

    private V6_NON_GLOBAL = [
      {0x00000000000000000000000000000000_u128, 128},
      {0x00000000000000000000000000000001_u128, 128},
      {0x00000000000000000000FFFF00000000_u128, 96},
      {0x00000000000000000000000000000100_u128, 64},
      {0x20000000000000000000000000000000_u128, 23},
      {0x20010DB8000000000000000000000000_u128, 32},
      {0x20020000000000000000000000000000_u128, 16},
      {0x3FFE0000000000000000000000000000_u128, 16},
      {0xFE800000000000000000000000000000_u128, 10},
      {0xFC000000000000000000000000000000_u128, 7},
      {0xFF000000000000000000000000000000_u128, 8},
    ]

    # ---- parsing ----

    def parse_value(str : String) : Net?
      s = str.strip
      return nil if s.empty?

      if s.matches?(/^\d+$/)
        n = s.to_u128?
        return nil unless n
        if n <= 0xFFFFFFFF_u128
          Net.new(4, n, 32, "address")
        else
          Net.new(6, n, 128, "address")
        end
      elsif slash = s.index('/')
        addr = s[0, slash]
        pref = s[(slash + 1)..]
        if addr.matches?(/^\d+$/) && pref.matches?(/^\d+$/)
          a = addr.to_u128?
          p = pref.to_i32?
          return nil unless a && p
          if a <= 0xFFFFFFFF_u128 && p <= 32
            Net.new(4, a, p, "network")
          elsif p <= 128
            Net.new(6, a, p, "network")
          else
            nil
          end
        else
          parse_qualified(addr, pref)
        end
      else
        parse_bare(s)
      end
    end

    private def parse_qualified(addr : String, pref : String) : Net?
      p = pref.to_i32?
      return nil unless p && p >= 0
      if addr.includes?(':')
        return nil if p > 128
        ip = parse_v6(addr)
        return nil unless ip
        Net.new(6, ip, p, "network")
      else
        return nil if p > 32
        ip = parse_v4(addr)
        return nil unless ip
        Net.new(4, ip, p, "network")
      end
    end

    private def parse_bare(s : String) : Net?
      if s.includes?(':')
        ip = parse_v6(s)
        return nil unless ip
        Net.new(6, ip, 128, "address")
      else
        ip = parse_v4(s)
        return nil unless ip
        Net.new(4, ip, 32, "address")
      end
    end

    def parse_v4(s : String) : UInt128?
      parts = s.split('.')
      return nil unless parts.size == 4
      value = 0_u128
      parts.each do |part|
        return nil unless part.matches?(/^\d+$/)
        octet = part.to_u32?
        return nil unless octet && octet <= 255
        value = (value << 8) | octet
      end
      value
    end

    def parse_v6(s : String) : UInt128?
      s = s.strip

      if s.index('.')
        colon = s.rindex(':')
        return nil unless colon
        tail_start = colon + 1
        v4 = parse_v4(s[tail_start..])
        return nil unless v4
        s = "#{s[0...tail_start]}#{(v4 >> 16).to_s(16)}:#{(v4 & 0xFFFF).to_s(16)}"
      end

      double = s.index("::")
      if double
        return nil if s.index("::", double + 1)
        left = s[0, double]
        right = s[(double + 2)..]
        lg = left.empty? ? [] of UInt32 : left.split(':').map { |group| parse_v6_group(group) }
        rg = right.empty? ? [] of UInt32 : right.split(':').map { |group| parse_v6_group(group) }
        return nil if lg.includes?(nil) || rg.includes?(nil)
        missing = 8 - lg.size - rg.size
        return nil if missing < 1
        groups = lg.compact + Array(UInt32).new(missing, 0_u32) + rg.compact
      else
        raw = s.split(':').map { |group| parse_v6_group(group) }
        return nil if raw.includes?(nil) || raw.size != 8
        groups = raw.compact
      end

      value = 0_u128
      groups.each { |group| value = (value << 16) | group }
      value
    end

    private def parse_v6_group(g : String) : UInt32?
      return nil if g.empty? || g.size > 4
      return nil unless g.matches?(/^[0-9a-fA-F]+$/)
      g.to_u32(16)
    end

    # ---- formatting ----

    def format_v4(ip : UInt128) : String
      "#{(ip >> 24) & 0xFF}.#{(ip >> 16) & 0xFF}.#{(ip >> 8) & 0xFF}.#{ip & 0xFF}"
    end

    def format_v6(ip : UInt128) : String
      if ip >> 96 == 0xFFFF
        return "::ffff:#{format_v4(ip & 0xFFFFFFFF_u128)}"
      end

      groups = Array(UInt32).new(8)
      8.times { |i| groups << (((ip >> (112 - 16 * i)) & 0xFFFF).to_u32) }

      best_start = -1
      best_len = 0
      i = 0
      while i < 8
        if groups[i] == 0
          j = i
          while j < 8 && groups[j] == 0
            j += 1
          end
          if j - i > best_len && j - i > 1
            best_len = j - i
            best_start = i
          end
          i = j
        else
          i += 1
        end
      end

      if best_start == -1
        return groups.join(":")
      end

      pieces = [] of String
      i = 0
      while i < 8
        if i == best_start
          pieces << ""
          i += best_len
          pieces << "" if i == 8
        else
          pieces << groups[i].to_s(16)
          i += 1
        end
      end
      pieces.join(":")
    end

    def format_ip(version : Int32, ip : UInt128) : String
      version == 4 ? format_v4(ip) : format_v6(ip)
    end

    def format_net(net : Net) : String
      "#{format_ip(net.version, net.ip)}/#{net.prefixlen}"
    end

    def format_cidr(net : Net) : String
      "#{format_ip(net.version, net.network)}/#{net.prefixlen}"
    end

    def json_int(n : UInt128) : JSON::Any
      if n <= Int64::MAX.to_u128
        JSON::Any.new(n.to_i64)
      else
        JSON::Any.new(n.to_f64)
      end
    end

    private FALSE = JSON::Any.new(false)

    # ---- main entry ----

    def ipaddr(value : JSON::Any, query : String = "", version : Int32? = nil, alias_name : String = "ipaddr") : JSON::Any
      case raw = value.raw
      when Nil, Bool
        return FALSE
      when String
        s = raw
      when Int64, Int32, Float64
        s = raw.to_s
      when Array
        results = raw.map do |element|
          ipaddr(JSON::Any.new(element.raw), query, version, alias_name)
        end.reject do |result|
          result.raw == false || result.raw.nil?
        end
        return JSON::Any.new(results)
      else
        raise IpError.new("Unrecognized type <#{raw.class}> for #{alias_name} filter <value>")
      end

      net = parse_value(s)
      return FALSE unless net

      if version && net.version != version
        return FALSE
      end

      # the digit / numeric-CIDR parse paths rewrite the pass-through
      # text to netaddr's own spelling (probed live: an integer input
      # comes back as '192.168.0.1/32' for prefix-preserving queries)
      value_text = s
      if s.matches?(/^\d+$/) || s.matches?(/^\d+\/\d+$/)
        value_text = format_net(net)
      end

      q = query.strip

      if !q.empty? && !q.matches?(/^\d+$/) && !QUERY_NAMES.includes?(q)
        return cidr_lookup(net, q, value_text) if parse_value(q)
      end

      run_query(net, q, value_text, alias_name)
    end

    private QUERY_NAMES = Set{
      "", "6to4", "address", "address/prefix", "bool", "broadcast",
      "cidr", "cidr_lookup", "first_usable", "gateway", "gw", "host",
      "host/prefix", "hostmask", "hostnet", "int", "ip", "ip/prefix",
      "ip_netmask", "ipv4", "ipv6", "last_usable", "link-local", "lo",
      "loopback", "multicast", "net", "next_usable", "netmask",
      "network", "network_id", "network/prefix", "network_netmask",
      "network_wildcard", "peer", "prefix", "previous_usable",
      "private", "public", "range_usable", "revdns", "router", "size",
      "size_usable", "subnet", "type", "unicast", "v4", "v6",
      "version", "wildcard", "wrap",
    }

    private def cidr_lookup(net : Net, q : String, value_text : String) : JSON::Any
      qnet = parse_value(q)
      return FALSE unless qnet
      if net.network >= qnet.network && net.broadcast <= qnet.broadcast
        JSON::Any.new(value_text)
      else
        FALSE
      end
    end

    private def run_query(net : Net, q : String, value_text : String, alias_name : String) : JSON::Any
      str_ip = format_ip(net.version, net.ip)

      case q
      when ""
        net.vtype == "address" ? JSON::Any.new(str_ip) : JSON::Any.new(format_net(net))
      when "address", "ip"
        sz = net.size || return FALSE
        if sz == 1
          JSON::Any.new(str_ip)
        elsif net.ip != net.network || net.version == 6 || net.prefixlen >= net.width - 1
          JSON::Any.new(str_ip)
        else
          FALSE
        end
      when "address/prefix", "gateway", "gw", "hostnet", "host/prefix", "router"
        sz = net.size || return FALSE
        if sz > 2 && (net.ip == net.network || net.ip == net.broadcast)
          FALSE
        else
          JSON::Any.new("#{str_ip}/#{net.prefixlen}")
        end
      when "bool"
        JSON::Any.new(true)
      when "broadcast"
        sz = net.size || return FALSE
        sz > 2 ? JSON::Any.new(format_ip(net.version, net.broadcast)) : FALSE
      when "cidr"
        JSON::Any.new(format_net(net))
      when "first_usable"
        first_last_usable(net, "first")
      when "last_usable"
        first_last_usable(net, "last")
      when "host"
        sz = net.size || return FALSE
        if sz == 1
          JSON::Any.new(format_net(net))
        elsif net.ip != net.network || net.prefixlen >= net.width - 1
          JSON::Any.new("#{str_ip}/#{net.prefixlen}")
        else
          FALSE
        end
      when "hostmask", "wildcard"
        JSON::Any.new(format_ip(net.version, net.hostmask))
      when "int"
        if net.vtype == "address"
          json_int(net.ip)
        else
          JSON::Any.new("#{net.ip}/#{net.prefixlen}")
        end
      when "ip/prefix"
        sz = net.size || return FALSE
        if sz == 2 || (sz > 1 && net.ip != net.network)
          JSON::Any.new("#{str_ip}/#{net.prefixlen}")
        else
          FALSE
        end
      when "ip_netmask"
        sz = net.size || return FALSE
        if sz == 2 || (sz > 1 && net.ip != net.network)
          JSON::Any.new("#{str_ip} #{format_ip(net.version, net.netmask)}")
        else
          FALSE
        end
      when "ipv4", "v4"
        if net.version == 6
          new_prefix = net.prefixlen >= 96 ? net.prefixlen - 96 : 32
          JSON::Any.new("#{format_v4(net.ip & 0xFFFFFFFF_u128)}/#{new_prefix}")
        else
          JSON::Any.new(value_text)
        end
      when "ipv6", "v6"
        if net.version == 4
          JSON::Any.new("::ffff:#{format_v4(net.ip)}/128")
        else
          JSON::Any.new(value_text)
        end
      when "link-local"
        net.link_local? ? JSON::Any.new(value_text) : FALSE
      when "loopback", "lo"
        net.loopback? ? JSON::Any.new(value_text) : FALSE
      when "multicast"
        net.multicast? ? JSON::Any.new(value_text) : FALSE
      when "net"
        sz = net.size || return FALSE
        if sz > 1 && net.ip == net.network
          JSON::Any.new(format_cidr(net))
        else
          FALSE
        end
      when "next_usable"
        nth_usable(net, 1)
      when "previous_usable"
        nth_usable(net, -1)
      when "netmask"
        JSON::Any.new(format_ip(net.version, net.netmask))
      when "network", "network_id"
        JSON::Any.new(format_ip(net.version, net.network))
      when "network/prefix"
        JSON::Any.new(format_cidr(net))
      when "network_netmask"
        JSON::Any.new("#{format_ip(net.version, net.network)} #{format_ip(net.version, net.netmask)}")
      when "network_wildcard"
        JSON::Any.new("#{format_ip(net.version, net.network)} #{format_ip(net.version, net.hostmask)}")
      when "peer"
        peer_query(net)
      when "prefix"
        JSON::Any.new(net.prefixlen.to_i64)
      when "private"
        net.global? ? FALSE : JSON::Any.new(value_text)
      when "public"
        if net.unicast? && net.global? && !net.loopback? &&
           !netmask_pattern?(net.version, net.ip) &&
           !hostmask_pattern?(net.version, net.ip)
          JSON::Any.new(value_text)
        else
          FALSE
        end
      when "range_usable"
        first_last_usable(net, "range")
      when "revdns"
        revdns(net)
      when "size"
        sz = net.size
        sz ? json_int(sz) : JSON::Any.new(3.4e38)
      when "size_usable"
        sz = net.size || return JSON::Any.new(0_i64)
        if sz == 1
          JSON::Any.new(0_i64)
        elsif sz == 2
          JSON::Any.new(2_i64)
        else
          json_int(sz - 2)
        end
      when "subnet"
        JSON::Any.new(format_cidr(net))
      when "type"
        if net.size.try(&.==(1)) || net.ip != net.network
          JSON::Any.new("address")
        else
          JSON::Any.new("network")
        end
      when "unicast"
        net.unicast? ? JSON::Any.new(value_text) : FALSE
      when "version"
        JSON::Any.new(net.version.to_i64)
      when "wrap"
        if net.version == 6
          if net.vtype == "address"
            JSON::Any.new("[#{format_ip(net.version, net.ip)}]")
          else
            JSON::Any.new("[#{format_ip(net.version, net.ip)}]/#{net.prefixlen}")
          end
        else
          JSON::Any.new(value_text)
        end
      else
        if idx = integer_query?(q)
          numeric_index_query(net, idx)
        else
          raise IpError.new("#{alias_name}: unknown filter type: #{q}")
        end
      end
    end

    private def integer_query?(q : String) : Int32?
      return nil unless q.matches?(/^-?\d+$/)
      q.to_i32?
    end

    private def netmask_pattern?(version : Int32, ip : UInt128) : Bool
      width = version == 4 ? 32 : 128
      return false if ip == 0
      z = 0
      m = ip
      while m & 1 == 0
        z += 1
        m >>= 1
      end
      z + ip.popcount == width
    end

    private def hostmask_pattern?(version : Int32, ip : UInt128) : Bool
      max = version == 4 ? 0xFFFFFFFF_u128 : UInt128::MAX
      inv = ~ip & max
      return false if inv == 0
      netmask_pattern?(version, inv)
    end

    private def first_last_usable(net : Net, which : String) : JSON::Any
      raise IpError.new("Not a network address") if net.vtype == "address"
      first = net.first_usable
      last = net.last_usable
      if which == "first"
        first ? JSON::Any.new(format_ip(net.version, first)) : FALSE
      elsif which == "last"
        last ? JSON::Any.new(format_ip(net.version, last)) : FALSE
      else
        first && last ? JSON::Any.new("#{format_ip(net.version, first)}-#{format_ip(net.version, last)}") : FALSE
      end
    end

    private def nth_usable(net : Net, offset : Int32) : JSON::Any
      if net.vtype == "address"
        raise IpError.new("Not a network address")
      end
      first = net.first_usable
      last = net.last_usable
      return FALSE unless first && last

      target = nil
      if offset >= 0
        target = net.ip + offset if net.ip <= net.max_int - offset
      else
        back = (-offset).to_u128
        target = net.ip - back if net.ip >= back
      end
      return FALSE unless target

      if target >= first && target <= last
        JSON::Any.new(format_ip(net.version, target))
      else
        FALSE
      end
    end

    private def peer_query(net : Net) : JSON::Any
      raise IpError.new("Not a network address") if net.vtype == "address"
      sz = net.size
      raise IpError.new("Not a point-to-point network") unless sz
      if sz == 2
        JSON::Any.new(format_ip(net.version, net.ip ^ 1))
      elsif sz == 4
        raise IpError.new("Network address of /30 has no peer") if net.ip % 4 == 0
        raise IpError.new("Broadcast address of /30 has no peer") if net.ip % 4 == 3
        JSON::Any.new(format_ip(net.version, net.ip ^ 3))
      else
        raise IpError.new("Not a point-to-point network")
      end
    end

    private def numeric_index_query(net : Net, idx : Int32) : JSON::Any
      sz = net.size || return FALSE
      if sz == 1
        return net.vtype == "address" ? JSON::Any.new(format_ip(net.version, net.ip)) : JSON::Any.new(format_net(net))
      end
      abs = if idx >= 0
              idx.to_u128
            else
              off = (-idx).to_u128
              return FALSE if off > sz
              sz - off
            end
      return FALSE if abs >= sz
      target = net.network + abs
      JSON::Any.new("#{format_ip(net.version, target)}/#{net.prefixlen}")
    end

    private def revdns(net : Net) : JSON::Any
      if net.version == 4
        octets = [net.ip & 0xFF, (net.ip >> 8) & 0xFF, (net.ip >> 16) & 0xFF, (net.ip >> 24) & 0xFF]
        JSON::Any.new("#{octets.map(&.to_s).join('.')}.in-addr.arpa.")
      else
        nibbles = Array(String).new(32)
        32.times do |i|
          nibbles << (((net.ip >> (124 - 4 * i)) & 0xF).to_u32).to_s(16)
        end
        JSON::Any.new("#{nibbles.reverse.join('.')}.ip6.arpa.")
      end
    end

    # ---- sibling filters ----

    def ipwrap(value : JSON::Any, query : String = "") : JSON::Any
      if value.raw.is_a?(Array)
        JSON::Any.new(value.as_a.map do |element|
          if ipaddr(element, query).raw == false
            element
          else
            wrapped = ipaddr(element, "wrap")
            wrapped.raw == false ? element : wrapped
          end
        end)
      else
        checked = ipaddr(value, query)
        return value if checked.raw == false
        wrapped = ipaddr(checked, "wrap")
        wrapped.raw == false ? value : wrapped
      end
    rescue IpError
      value
    end

    def ipsubnet(value : JSON::Any, query : String, index : String? = nil) : JSON::Any
      vtype = ipaddr(value, "type")
      return FALSE if vtype.raw == false
      v = vtype.as_s == "address" ? ipaddr(value, "cidr") : ipaddr(value, "subnet")
      return FALSE if v.raw == false

      vnet = parse_value(v.as_s)
      return FALSE unless vnet
      bits = vnet.width

      return JSON::Any.new(format_net(vnet)) if query.strip.empty?

      qs = query.strip
      if qs.matches?(/^\d+$/)
        qn = qs.to_i32?
        return FALSE unless qn
        return FALSE if qn < 0 || qn > bits

        if index.nil?
          if vnet.type_query == "address"
            JSON::Any.new(format_cidr(Net.new(vnet.version, vnet.ip, qn, "network")))
          else
            raise IpError.new("Requested subnet size of #{qn} is invalid") if qn < vnet.prefixlen
            json_int(1_u128 << (qn - vnet.prefixlen))
          end
        else
          idx = index.strip.to_i32?
          return FALSE unless idx
          if vnet.type_query == "address"
            span = vnet.prefixlen - qn
            return FALSE if idx < 0 || idx > span
            JSON::Any.new(format_cidr(Net.new(vnet.version, vnet.ip, qn + idx, "network")))
          else
            subnets = 1_u128 << (qn - vnet.prefixlen)
            idx += subnets.to_i32 if idx < 0
            return FALSE if idx < 0 || idx.to_u128 >= subnets
            target = vnet.network + (idx.to_u128 << (bits - qn))
            JSON::Any.new("#{format_ip(vnet.version, target)}/#{qn}")
          end
        end
      else
        qtype = ipaddr(JSON::Any.new(qs), "type")
        raise IpError.new("You must pass a valid subnet or IP address; #{qs} is invalid") if qtype.raw == false
        qv = qtype.as_s == "address" ? ipaddr(JSON::Any.new(qs), "cidr") : ipaddr(JSON::Any.new(qs), "subnet")
        raise IpError.new("You must pass a valid subnet or IP address; #{qs} is invalid") if qv.raw == false
        qnet = parse_value(qv.as_s)
        return FALSE unless qnet

        vshift = bits - qnet.prefixlen
        head_v = vshift >= bits ? 0_u128 : vnet.ip >> vshift
        head_q = vshift >= bits ? 0_u128 : qnet.ip >> vshift
        if head_v == head_q
          mask_span = vnet.prefixlen - qnet.prefixlen
          inner = mask_span <= 0 ? 0_u128 : (((1_u128 << mask_span) - 1) << (bits - vnet.prefixlen))
          result = ((vnet.ip & inner) >> (bits - vnet.prefixlen)) + 1
          json_int(result)
        else
          raise IpError.new("#{format_cidr(vnet)} is not in the subnet #{format_cidr(qnet)}")
        end
      end
    end

    def ipmath(value : JSON::Any, amount : Int64) : JSON::Any
      s = value.as_s?.try(&.strip) || (value.raw.is_a?(Int64 | Int32 | Float64) ? value.to_s : "")
      raise IpError.new("You must pass a valid IP address; #{s} is invalid") if s.empty?

      parsed = parse_ipmath_base(s)
      raise IpError.new("You must pass a valid IP address; #{s} is invalid") unless parsed

      base, version = parsed
      result = shifted_base(base, amount)
      raise IpError.new("You must pass a valid IP address; #{s} is invalid") unless result
      width = version == 4 ? 32 : 128
      raise IpError.new("You must pass a valid IP address; #{s} is invalid") if result >> width != 0
      JSON::Any.new(format_ip(version, result))
    end

    private def parse_ipmath_base(s : String) : {UInt128, Int32}?
      net = parse_value(s)
      return nil unless net
      {net.ip, net.version}
    end

    private def shifted_base(base : UInt128, amount : Int64) : UInt128?
      if amount >= 0
        base + amount.to_u128 if base <= UInt128::MAX - amount.to_u128
      else
        back = (-amount).to_u128
        base - back if base >= back
      end
    end

    def next_nth_usable(value : JSON::Any, offset : Int64) : JSON::Any
      net = normalize_for_range(value)
      return FALSE unless net
      raise IpError.new("Must pass in an integer") unless offset.is_a?(Int64)
      nth_usable(net, offset.to_i32)
    end

    def previous_nth_usable(value : JSON::Any, offset : Int64) : JSON::Any
      net = normalize_for_range(value)
      return FALSE unless net
      raise IpError.new("Must pass in an integer") unless offset.is_a?(Int64)
      nth_usable(net, -offset.to_i32)
    end

    private def normalize_for_range(value : JSON::Any) : Net?
      vtype = ipaddr(value, "type")
      return nil if vtype.raw == false
      v = vtype.as_s == "address" ? ipaddr(value, "cidr") : ipaddr(value, "subnet")
      return nil if v.raw == false
      parse_value(v.as_s)
    end

    def network_in_network(value : JSON::Any, test : JSON::Any) : JSON::Any
      in_range(value, test, usable_only: false)
    end

    def network_in_usable(value : JSON::Any, test : JSON::Any) : JSON::Any
      in_range(value, test, usable_only: true)
    end

    private def in_range(value : JSON::Any, test : JSON::Any, usable_only : Bool) : JSON::Any
      v = normalize_for_range(value)
      w = normalize_for_range(test)
      return FALSE unless v && w

      if usable_only
        v_first = v.first_usable || v.ip
        v_last = v.last_usable || v.ip
      else
        v_first = v.network
        v_last = v.size.try(&.>(2)) ? v.broadcast : v.ip
      end
      w_first = w.network
      w_last = w.size.try(&.>(2)) ? w.broadcast : w.ip

      if w_first >= v_first && w_last <= v_last
        JSON::Any.new(true)
      else
        FALSE
      end
    end

    def ip4_hex(value : JSON::Any, delimiter : String = "") : JSON::Any
      s = value.as_s?.try(&.strip) || (value.raw.is_a?(Int64 | Int32 | Float64) ? value.to_s : "")
      ip = parse_v4(s)
      raise IpError.new("You must pass a valid IP address; #{s} is invalid") unless ip
      octets = [((ip >> 24) & 0xFF), ((ip >> 16) & 0xFF), ((ip >> 8) & 0xFF), (ip & 0xFF)]
      hexes = octets.map { |octet| sprintf("%02x", octet.to_u64) }
      JSON::Any.new(hexes.join(delimiter))
    end
  end
end
