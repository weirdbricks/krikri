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
      SUPPORTED_THINGS = %w[service port rich_rule source masquerade]

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

      # masquerade takes no value (`--add-masquerade`, not
      # `--add-masquerade=true`) - every other supported thing does.
      # Single-quoted (not double-quoted) since a rich_rule value
      # contains embedded double quotes of its own
      # (`rule family="ipv4" ...`) - single quotes need no escaping of
      # those. Caught by an actual failure running a real rich_rule
      # against firewall-offline-cmd with the value left unquoted.
      private def self.value_suffix(thing : String, value : String) : String
        thing == "masquerade" ? "" : "='#{value}'"
      end
    end
  end
end
