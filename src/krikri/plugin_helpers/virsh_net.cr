require "json"

module Krikri
  module PluginHelpers
    # VirshNet - command construction and output parsing for
    # community.libvirt.virt_net (see plugins/virt_net.cr). Pure string
    # plumbing mirroring the real module's LibvirtConnection/VirtNetwork
    # helpers, unit-testable without a libvirt daemon.
    module VirshNet
      record DhcpHost, mac : String, name : String?, ip : String?

      # Parses `virsh net-info <name>` output. Active/Autostart/
      # Persistent are yes/no; Bridge can be legitimately absent
      # (a network with no bridge yet) and is nil then.
      def self.parse_net_info(output : String) : {active: Bool?, autostart: Bool?, persistent: Bool?, bridge: String?}
        active = nil
        autostart = nil
        persistent = nil
        bridge = nil

        output.each_line do |line|
          key, _, value = line.partition(':')
          value = value.strip
          case key.strip
          when "Active"    then active = value == "yes"
          when "Autostart" then autostart = value == "yes"
          when "Persistent" then persistent = value == "yes"
          when "Bridge"    then bridge = value.empty? ? nil : value
          end
        end

        {active: active, autostart: autostart, persistent: persistent, bridge: bridge}
      end

      # forward_mode / domain / macaddress come from the network's XML
      # (the real module xpath-scans XMLDesc) - regex equivalents over
      # `virsh net-dumpxml` output, nil when the element is absent
      # (matching the real module's "skip the fact" behavior).
      def self.parse_forward_mode(xml : String) : String?
        xml.match(/<forward[^>]*\smode=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_domain(xml : String) : String?
        xml.match(/<domain[^>]*\sname=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_macaddress(xml : String) : String?
        xml.match(/<mac[^>]*\saddress=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_dhcp_hosts(xml : String) : Array(DhcpHost)
        xml.scan(/<host\b[^>]*\/?>/).compact_map do |match|
          tag = match[0]
          mac = tag.match(/\smac=['"]([^'"]+)['"]/).try(&.[1])
          next nil unless mac
          name = tag.match(/\sname=['"]([^'"]+)['"]/).try(&.[1])
          ip = tag.match(/\sip=['"]([^'"]+)['"]/).try(&.[1])
          DhcpHost.new(mac, name, ip)
        end
      end

      # All command builders take the connection URI (the real module
      # always opens its own connection with it, default
      # qemu:///system - same default virsh itself uses).
      def self.virsh(uri : String, subcommand : String, *args : String) : Array(String)
        ["virsh", "--connect", uri, subcommand, *args]
      end

      # `modify`'s virsh net-update mapping for a <host/> DHCP entry -
      # the one section the real module implements (ADD_LAST /
      # IP_DHCP_HOST), applied live+config when the network is active
      # and config-only when it isn't.
      def self.net_update_command(uri : String, name : String, xml : String, live : Bool) : Array(String)?
        return nil unless xml.lstrip.starts_with?("<host")
        cmd = virsh(uri, "net-update", name, "add-last", "ip-dhcp-host", xml)
        cmd += ["--live", "--config"] if live
        cmd << "--config" unless live
        cmd
      end
    end
  end
end
