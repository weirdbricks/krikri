require "json"

module CrystalPlay
  # NetworkFacts - Gathers network-related facts
  module NetworkFacts
    # Gather network facts
    # Populates: ansible_default_ipv4, ansible_all_ipv4_addresses
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_default_ipv4 - default IPv4 address
      ipv4 = execute_callback.call("ip -4 route get 1 2>/dev/null | head -1 | awk '{print $7}'")
      if ipv4 && !ipv4.strip.empty?
        facts["ansible_default_ipv4"] = JSON::Any.new({
          "address" => ipv4.strip
        })
      end
      
      # ansible_all_ipv4_addresses - all IPv4 addresses
      all_ipv4 = execute_callback.call("ip -4 addr show | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
      if all_ipv4
        addresses = all_ipv4.split("\n").map(&.strip).reject(&.empty?)
        facts["ansible_all_ipv4_addresses"] = JSON::Any.new(addresses.map { |a| JSON::Any.new(a) })
      end
      
      # ansible_hostname with IP fallback
      unless facts["ansible_hostname"]?
        if ipv4 && !ipv4.strip.empty?
          facts["ansible_hostname"] = JSON::Any.new(ipv4.strip)
        end
      end
    end
  end
end
