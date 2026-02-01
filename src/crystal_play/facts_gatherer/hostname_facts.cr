require "json"

module CrystalPlay
  # HostnameFacts - Gathers hostname-related facts
  module HostnameFacts
    # Gather hostname facts
    # Populates: ansible_hostname, ansible_fqdn, ansible_nodename, ansible_domain
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_hostname - short hostname
      result = execute_callback.call("hostname -s")
      facts["ansible_hostname"] = JSON::Any.new(result.strip) if result
      
      # ansible_fqdn - fully qualified domain name
      result = execute_callback.call("hostname -f")
      facts["ansible_fqdn"] = JSON::Any.new(result.strip) if result
      
      # ansible_nodename - same as hostname
      facts["ansible_nodename"] = facts["ansible_hostname"] if facts["ansible_hostname"]?
      
      # ansible_domain - domain name
      if fqdn = facts["ansible_fqdn"]?.try(&.as_s)
        if hostname = facts["ansible_hostname"]?.try(&.as_s)
          domain = fqdn.gsub(/^#{hostname}\./, "")
          facts["ansible_domain"] = JSON::Any.new(domain) unless domain.empty?
        end
      end
    end
  end
end
