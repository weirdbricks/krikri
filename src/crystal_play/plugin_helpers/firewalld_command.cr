module CrystalPlay
  module PluginHelpers
    # FirewalldCommand - pure logic for building `firewall-offline-cmd`
    # command lines. No I/O here - the plugin itself runs the resulting
    # commands.
    #
    # `--zone=<zone> --query-<thing>=<value>` exits 0/prints "yes" if
    # present, exits 1/prints "no" if absent - verified empirically
    # against a real `firewall-offline-cmd` (firewalld 2.1.1) in a real
    # container, since this behavior isn't documented in ansible-doc at
    # all (it belongs to firewall-offline-cmd itself, a companion CLI
    # tool, not the Ansible module).
    #
    # `service` removal is a real, confirmed quirk: `--remove-service`
    # (no `-from-zone` suffix) is a legacy "lokkit" option that can't be
    # combined with `--zone=` at all (real, verified error: "Can't use
    # lokkit options with other options") - the zone-scoped removal form
    # is `--remove-service-from-zone=`. `port`/`rich-rule`/`source`/
    # `masquerade` don't have this quirk; their plain `--remove-<thing>=`
    # forms work fine with `--zone=`.
    module FirewalldCommand
      SUPPORTED_THINGS = %w[service port rich_rule source masquerade interface icmp_block protocol icmp_block_inversion forward]

      # Things whose add/remove/query flags take NO value at all
      # (`--add-masquerade`, not `--add-masquerade=true`) - verified
      # empirically against a real `firewall-offline-cmd` (firewalld
      # 2.3.1) in a real container for icmp_block_inversion/forward too,
      # the same way masquerade originally was.
      NO_VALUE_THINGS = %w[masquerade icmp_block_inversion forward]

      # Returns nil if none or more than one "thing" param is present -
      # matches real Ansible's own mutually_exclusive constraint (exactly
      # one of service/port/rich_rule/source/masquerade/etc per task).
      def self.thing(params : Hash(String, String)) : {String, String}?
        present = SUPPORTED_THINGS.select { |key| params[key]? }
        return nil unless present.size == 1

        key = present[0]
        {key, params[key]}
      end

      def self.flag_name(thing : String) : String
        thing == "rich_rule" ? "rich-rule" : thing.gsub('_', '-')
      end

      def self.query_command(zone : String, thing : String, value : String) : String
        "firewall-offline-cmd --zone=#{zone} --query-#{flag_name(thing)}#{value_suffix(thing, value)}"
      end

      def self.add_command(zone : String, thing : String, value : String) : String
        "firewall-offline-cmd --zone=#{zone} --add-#{flag_name(thing)}#{value_suffix(thing, value)}"
      end

      def self.remove_command(zone : String, thing : String, value : String) : String
        flag = thing == "service" ? "remove-service-from-zone" : "remove-#{flag_name(thing)}"
        "firewall-offline-cmd --zone=#{zone} --#{flag}#{value_suffix(thing, value)}"
      end

      # Single-quoted (not double-quoted) since a rich_rule value
      # contains embedded double quotes of its own
      # (`rule family="ipv4" ...`) - single quotes need no escaping of
      # those. Caught by an actual failure running a real rich_rule
      # against firewall-offline-cmd with the value left unquoted.
      private def self.value_suffix(thing : String, value : String) : String
        NO_VALUE_THINGS.includes?(thing) ? "" : "='#{value}'"
      end

      # Builds the compound `port=X:proto=Y:toport=Z[:toaddr=W]` value
      # real Ansible's own `ForwardPortTransaction` builds from a
      # `port_forward:` entry (a dict with `port`/`proto`/`toport`
      # required, `toaddr` optional and simply omitted from the value
      # when absent - verified against the real module's own source and
      # live against a real `firewall-offline-cmd`, firewalld 1.3.3).
      # Returns {value: nil, error: "..."} with the exact error message
      # real Ansible raises (checked in the same port/proto/toport order
      # the real module checks them) when a required key is missing, or
      # {value: "port=...", error: nil} on success.
      def self.port_forward_value(entry : JSON::Any) : {value: String?, error: String?}
        port = entry["port"]?
        return {value: nil, error: "port must be specified for port forward"} unless port

        proto = entry["proto"]?
        return {value: nil, error: "proto udp/tcp must be specified for port forward"} unless proto

        toport = entry["toport"]?
        return {value: nil, error: "toport must be specified for port forward"} unless toport

        toaddr = entry["toaddr"]?.try(&.to_s) || ""
        value = "port=#{port}:proto=#{proto}:toport=#{toport}"
        value += ":toaddr=#{toaddr}" unless toaddr.empty?

        {value: value, error: nil}
      end

      def self.forward_port_query_command(zone : String, value : String) : String
        "firewall-offline-cmd --zone=#{zone} --query-forward-port='#{value}'"
      end

      def self.forward_port_add_command(zone : String, value : String) : String
        "firewall-offline-cmd --zone=#{zone} --add-forward-port='#{value}'"
      end

      def self.forward_port_remove_command(zone : String, value : String) : String
        "firewall-offline-cmd --zone=#{zone} --remove-forward-port='#{value}'"
      end
    end
  end
end
