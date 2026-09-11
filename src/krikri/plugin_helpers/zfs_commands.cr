module Krikri
  module PluginHelpers
    # ZfsCommands - command construction and output parsing for
    # community.general.zfs (see plugins/zfs.cr). Pure string plumbing
    # mirroring the real module's Zfs class (create/destroy/set_property/
    # list_properties/get_property), unit-testable without a ZFS pool.
    module ZfsCommands
      # The real module reverses Python bools to "on"/"off" before any
      # command is built; properties arrive here already normalized.
      def self.normalize_value(value : JSON::Any) : String
        case value.raw
        when true  then "on"
        when false then "off"
        else            value.to_s
        end
      end

      # The real module's create(): special-cases volsize (-V) and
      # volblocksize (-b), everything else -o prop=value; -p (parents)
      # for create/clone; snapshot instead of create when the name has
      # an @; clone when origin is set (mutually exclusive with @).
      def self.create_command(name : String, properties : Hash(String, String), origin : String?) : Array(String)?
        return nil if origin && name.includes?('@')

        action = if name.includes?('@')
                   "snapshot"
                 elsif origin
                   "clone"
                 else
                   "create"
                 end

        cmd = ["zfs", action]
        cmd << "-p" if action == "create" || action == "clone"

        properties.each do |prop, value|
          case prop
          when "volsize"     then cmd += ["-V", value]
          when "volblocksize" then cmd += ["-b", value]
          else                    cmd += ["-o", "#{prop}=#{value}"]
          end
        end

        cmd << origin if origin && action == "clone"
        cmd << name
        cmd
      end

      def self.destroy_command(name : String) : Array(String)
        ["zfs", "destroy", "-R", name]
      end

      def self.set_property_command(name : String, prop : String, value : String) : Array(String)
        ["zfs", "set", "#{prop}=#{value}", name]
      end

      def self.exists_command(name : String) : Array(String)
        ["zfs", "list", "-t", "all", name]
      end

      def self.list_properties_command(name : String) : Array(String)
        ["zfs", "get", "-H", "-p", "-o", "property,source", "all", name]
      end

      def self.property_value_command(name : String, prop : String) : Array(String)
        ["zfs", "get", "-H", "-p", "-o", "value", prop, name]
      end

      # Parses `zfs get -H -p -o property,source all <name>` output,
      # keeping only properties whose source is local/received/- (the
      # real module's own filter - creation-only properties are kept via
      # the '-' source so an existing dataset with an unchanged
      # creation-only property doesn't error on a warm run).
      def self.parse_list_properties(output : String) : Array(String)
        output.split('\n').reject(&.empty?).compact_map do |line|
          parts = line.split('\t')
          next nil if parts.size < 2
          next nil unless {"local", "received", "-"}.includes?(parts[1])
          parts[0]
        end
      end
    end
  end
end
