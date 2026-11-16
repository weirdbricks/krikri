require "json"

module Krikri
  module PluginHelpers
    # VirshPool - command construction and output parsing for
    # community.libvirt.virt_pool (see plugins/virt_pool.cr). Pure string
    # plumbing mirroring the Ansible module's LibvirtConnection/
    # VirtStoragePool helpers, unit-testable without a libvirt daemon.
    module VirshPool
      # `virsh pool-info` fields the Ansible module reads off a libvirt
      # pool handle. capacity/allocation/available are byte counts only
      # when queried with --bytes (otherwise libvirt prints "494.00 GiB",
      # which has no lossless byte equivalent) and stay nil then.
      record PoolInfo,
        name : String?,
        uuid : String?,
        state : String?,
        persistent : Bool?,
        autostart : Bool?,
        capacity : Int64?,
        allocation : Int64?,
        available : Int64?

      def self.parse_pool_info(output : String) : PoolInfo
        name = nil
        uuid = nil
        state = nil
        persistent = nil
        autostart = nil
        capacity = nil
        allocation = nil
        available = nil

        output.each_line do |line|
          key, _, value = line.partition(':')
          value = value.strip
          case key.strip
          when "Name"       then name = value
          when "UUID"       then uuid = value
          when "State"      then state = value
          when "Persistent" then persistent = value == "yes"
          when "Autostart"  then autostart = value == "yes"
          when "Capacity"   then capacity = value.to_i64?
          when "Allocation" then allocation = value.to_i64?
          when "Available"  then available = value.to_i64?
          end
        end

        PoolInfo.new(name: name, uuid: uuid, state: state, persistent: persistent,
          autostart: autostart, capacity: capacity, allocation: allocation, available: available)
      end

      # `virsh pool-list --all --name` - one pool name per line, no
      # header.
      def self.parse_pool_names(output : String) : Array(String)
        output.split("\n").map(&.strip).reject(&.empty?)
      end

      # virStoragePoolIsActive(): 0 only for a pool libvirt reports as
      # inactive. `virsh pool-info`'s State line carries the same
      # distinction (running/building/degraded vs inactive/inaccessible).
      def self.active_state?(state : String?) : Bool
        state ? !state.in?("inactive", "inaccessible") : false
      end

      # ENTRY_STATE_INFO_MAP.get(data[0], "unknown") - the five libvirt
      # pool state codes, by name, as pool-info prints them.
      def self.info_state(state : String?) : String
        state && state.in?("inactive", "building", "running", "degraded", "inaccessible") ? state : "unknown"
      end

      # The Ansible module xpath-scans the pool XML for these; regex
      # equivalents over `virsh pool-dumpxml` output, nil when the
      # element is absent (matching the "skip the fact" behavior its
      # ValueError catch produces).
      def self.parse_pool_type(xml : String) : String?
        xml.match(/<pool\b[^>]*\stype=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_target_path(xml : String) : String?
        xml.match(/<target\b[^>]*>\s*<path>([^<]*)<\/path>/m).try(&.[1])
      end

      def self.parse_source_section(xml : String) : String?
        xml.match(/<source\b[^>]*>(.*?)<\/source>/m).try(&.[1])
      end

      def self.parse_source_host(xml : String) : String?
        section = parse_source_section(xml) || return nil
        section.match(/<host\b[^>]*\sname=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_source_path(xml : String) : String?
        section = parse_source_section(xml) || return nil
        section.match(/<dir\b[^>]*\spath=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_source_format(xml : String) : String?
        section = parse_source_section(xml) || return nil
        section.match(/<format\b[^>]*\stype=['"]([^'"]+)['"]/).try(&.[1])
      end

      def self.parse_source_devices(xml : String) : Array(String)
        section = parse_source_section(xml) || return [] of String
        section.scan(/<device\b[^>]*\spath=['"]([^'"]+)['"]/).map(&.[1])
      end

      # All command builders take the connection URI (the Ansible module
      # always opens its own connection with it, default
      # qemu:///system - same default virsh itself uses).
      def self.virsh(uri : String, subcommand : String, *args : String) : Array(String)
        ["virsh", "--connect", uri, subcommand, *args]
      end

      # ENTRY_BUILD_FLAGS_MAP -> the flags virsh pool-build can express
      # (0 new, 4 no_overwrite, 8 overwrite). Real's repair(1)/resize(2)
      # have no virsh spelling and fall back to the plain build.
      def self.build_command(uri : String, name : String, mode : String?) : Array(String)
        cmd = ["virsh", "--connect", uri, "pool-build"]
        case mode
        when "no_overwrite" then cmd << "--no-overwrite"
        when "overwrite"    then cmd << "--overwrite"
        end
        cmd << name
      end

      def self.define_command(uri : String, path : String) : Array(String)
        virsh(uri, "pool-define", path)
      end
    end
  end
end
