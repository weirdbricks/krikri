module CrystalPlay
  module PluginHelpers
    # GroupState - pure logic for parsing `getent group` output and deciding
    # what (if anything) needs to change to reconcile a group with its
    # desired state. No I/O here: the plugin itself calls getent/groupadd/
    # etc and hands the results in as plain strings.
    module GroupState
      record Group, name : String, gid : String

      # Parses a single `getent group <name>` line: "name:password:gid:members"
      def self.parse(line : String) : Group?
        fields = line.strip.split(":")
        return nil if fields.size < 3
        Group.new(fields[0], fields[2])
      end

      # groupadd argument list for a brand new group.
      def self.groupadd_args(name : String, gid : String?, system : Bool) : Array(String)
        args = [] of String
        args << "-g #{gid}" if gid
        args << "-r" if system
        args << name
        args
      end

      # groupmod flags needed to reconcile an existing group with the
      # desired gid. Empty array means nothing to change.
      def self.groupmod_flags(current : Group, desired_gid : String?) : Array(String)
        return [] of String if desired_gid.nil? || desired_gid == current.gid
        ["-g #{desired_gid}"]
      end
    end
  end
end
