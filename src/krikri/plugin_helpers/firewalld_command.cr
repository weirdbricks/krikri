require "json"
require "krikri-xml"
require "../shell"

module Krikri
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
    #
    # The ZoneXml section below is the direct zone-config-file backend
    # for offline mode: real ansible.posix.firewalld's offline mode does
    # NOT shell out to firewall-offline-cmd at all - it uses firewalld's
    # own Python Firewall(offline=True), which loads the /usr/lib/
    # firewalld + /etc/firewalld zone XML into memory and writes changes
    # back to /etc/firewalld/zones/<zone>.xml. firewall-offline-cmd, by
    # contrast, dies entirely in environments where its protocol
    # validation can't resolve entries like 'esp' (getprotobyname('esp')
    # fails in a slim container), so a CLI-based offline backend
    # diverges from real Ansible in exactly the containerized hosts this
    # project targets. These helpers operate on the XML file CONTENT
    # only - the plugin owns the reads/writes/paths.
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

      # *binary* selects the runtime/live-daemon CLI (`firewall-cmd`,
      # talking to a running firewalld over D-Bus) vs the on-disk XML
      # editor (`firewall-offline-cmd`, no daemon needed) - the flags
      # after the binary are identical between the two.
      def self.query_command(zone : String, thing : String, value : String, binary : String = "firewall-offline-cmd") : String
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --query-#{flag_name(thing)}#{value_suffix(thing, value)}"
      end

      def self.add_command(zone : String, thing : String, value : String, binary : String = "firewall-offline-cmd") : String
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --add-#{flag_name(thing)}#{value_suffix(thing, value)}"
      end

      def self.remove_command(zone : String, thing : String, value : String, binary : String = "firewall-offline-cmd") : String
        flag = thing == "service" ? "remove-service-from-zone" : "remove-#{flag_name(thing)}"
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --#{flag}#{value_suffix(thing, value)}"
      end

      # Single-quoted (not double-quoted) since a rich_rule value
      # contains embedded double quotes of its own
      # (`rule family="ipv4" ...`) - single quotes need no escaping of
      # those. Caught by an actual failure running a real rich_rule
      # against firewall-offline-cmd with the value left unquoted.
      # Shell.single_quote (not a bare '#{'...'}' wrap) so an embedded
      # APOSTROPHE is escaped too - a bare wrap let a `'` in the value
      # terminate the quoting and run arbitrary commands under
      # /bin/bash -c.
      private def self.value_suffix(thing : String, value : String) : String
        NO_VALUE_THINGS.includes?(thing) ? "" : "=#{Shell.single_quote(value)}"
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

      def self.forward_port_query_command(zone : String, value : String, binary : String = "firewall-offline-cmd") : String
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --query-forward-port=#{Shell.single_quote(value)}"
      end

      def self.forward_port_add_command(zone : String, value : String, binary : String = "firewall-offline-cmd") : String
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --add-forward-port=#{Shell.single_quote(value)}"
      end

      def self.forward_port_remove_command(zone : String, value : String, binary : String = "firewall-offline-cmd") : String
        "#{binary} --zone=#{Shell.quote_if_needed(zone)} --remove-forward-port=#{Shell.single_quote(value)}"
      end

      # --- ZoneXml: direct zone-config-file (offline) backend ---

      # The XML element name + identifying attributes each "thing"
      # serializes to inside a zone config file. The compound value
      # shapes are firewalld's own file format: port is "N/proto" split
      # across the port/protocol attributes, everything else maps
      # attribute-for-attribute. rich_rule is absent here on purpose:
      # its string form parses through firewalld's own Rich_Rule into
      # arbitrarily nested <rule> XML, and a hand-rolled subset would
      # break query canonicalization (attribute order/equivalence), so
      # it stays on the firewall-offline-cmd path.
      def self.zone_element(thing : String, value : String) : {String, Hash(String, String)}
        case thing
        when "port"
          parts = value.split("/", 2)
          {"port", {"port" => parts[0], "protocol" => parts[1]? || ""}}
        when "service"
          {"service", {"name" => value}}
        when "source"
          {"source", {"address" => value}}
        when "interface"
          {"interface", {"name" => value}}
        when "icmp_block"
          {"icmp-block", {"name" => value}}
        when "protocol"
          {"protocol", {"value" => value}}
        else
          # masquerade, icmp_block_inversion, forward - the NO_VALUE_THINGS
          {thing.gsub('_', '-'), {} of String => String}
        end
      end

      # A <forward-port> element's identifying attributes for a
      # port_forward entry dict (port/proto required, toport required,
      # toaddr optional and simply absent from the element when not
      # given - matching the compound-value shape ForwardPortTransaction
      # builds).
      def self.forward_port_element(entry : JSON::Any) : {String, Hash(String, String)}
        attrs = {
          "port"     => entry["port"].to_s,
          "protocol" => entry["proto"].to_s,
          "to-port"  => entry["toport"].to_s,
        }
        if toaddr = entry["toaddr"]?
          attrs = attrs.merge({"to-addr" => toaddr.to_s})
        end
        {"forward-port", attrs}
      end

      # Does the zone XML already contain the element? (the query step -
      # exactly one element matching name + every identifying attribute)
      def self.zone_query(content : String, element : String, attrs : Hash(String, String)) : Bool
        root = zone_root(content)
        return false unless root
        root.elements.any? do |child|
          child.local_name == element &&
            attrs.all? { |key, value| child.attribute(key).try(&.value) == value }
        end
      end

      # Serialized zone XML with the element added, or nil if it's
      # already present (query-then-add stays the caller's idempotency
      # primitive, mirroring the CLI path's query exit code).
      def self.zone_add(content : String, element : String, attrs : Hash(String, String)) : String?
        root = zone_root(content)
        return nil unless root
        return nil if zone_query(content, element, attrs)
        rebuild(root, root.elements.map(&.to_xml) + [build_element(element, attrs)])
      end

      # Serialized zone XML with the element removed, or nil if it
      # wasn't present.
      def self.zone_remove(content : String, element : String, attrs : Hash(String, String)) : String?
        root = zone_root(content)
        return nil unless root
        matching = root.elements.select do |child|
          child.local_name == element &&
            attrs.all? { |key, value| child.attribute(key).try(&.value) == value }
        end
        return nil if matching.empty?
        kept = root.elements.reject { |child| matching.includes?(child) }
        rebuild(root, kept.map(&.to_xml))
      end

      # Serialized zone XML with the zone root's target attribute set
      # (or removed for "default" - a zone's target isn't optional the
      # way an entry is, absence IS "default").
      def self.zone_set_target(content : String, target : String) : String
        root = zone_root(content)
        return content unless root
        attr_line = root.attributes.reject { |a| a.name == "target" }.map { |a| %(#{a.name}="#{a.value}") }.join(" ")
        attr_line = " #{attr_line}" unless attr_line.empty?
        if target != "default"
          attr_line += %( target="#{target}")
        end
        "<zone#{attr_line}>\n#{root.elements.map(&.to_xml).join("\n")}\n</zone>\n"
      end

      private def self.zone_root(content : String) : KXML::Element?
        root = KXML.parse(content).root
        return nil unless root && root.local_name == "zone"
        root
      end

      private def self.build_element(element : String, attrs : Hash(String, String)) : String
        attr_s = attrs.map { |key, value| %( #{key}="#{value}") }.join
        "<#{element}#{attr_s}/>"
      end

      # Re-serializes the zone root with *children* as the full element
      # child list (text/whitespace nodes dropped - the output is
      # normalized one-element-per-line, which firewalld's own writer
      # also is). Callers pass the existing element children they want
      # kept plus any new ones.
      private def self.rebuild(root : KXML::Element, children : Array(String)) : String
        attr_line = root.attributes.map { |a| %(#{a.name}="#{a.value}") }.join(" ")
        attr_line = " #{attr_line}" unless attr_line.empty?
        "<zone#{attr_line}>\n#{children.join("\n")}\n</zone>\n"
      end
    end
  end
end
