require "../shell"

module Krikri
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

      # `local: true`'s existence check - real Ansible's own group_exists
      # reads /etc/group directly (its own comment: the grp module "does not
      # distinguish between local and directory accounts") instead of any
      # NSS query, scanning the file's lines REVERSED so the LAST matching
      # "name:" line wins. nil when the name isn't in the file at all.
      def self.local_parse(content : String, name : String) : Group?
        content.lines.reverse_each do |line|
          next unless line.starts_with?("#{name}:")
          return parse(line)
        end
        nil
      end

      # `local: true`'s gid-in-use pre-check - real Ansible's own
      # _local_check_gid_exists runs before every lgroupadd/lgroupmod with a
      # gid and fails when any NSS-visible group (grp.getgrall, so the full
      # listing, not a single-key lookup) already owns that gid under a
      # DIFFERENT name, even with non_unique: (live-verified: local create
      # with gid 4 fails "GID '4' already exists with group 'adm'" while the
      # same request without local is left to lgroupadd/groupadd's own
      # duplicate-gid handling). Returns the conflicting group's name, or nil
      # when the gid is free. Faithfully replicates the real module's
      # Python-truthiness quirk: `if self.gid:` means gid 0 skips the check
      # entirely (live-verified - gid 0 with a different name does NOT fail).
      def self.local_gid_conflict(content : String, name : String, gid : String) : String?
        return nil if gid == "0"
        content.each_line do |line|
          fields = line.strip.split(":")
          next if fields.size < 3
          return fields[0] if fields[2] == gid && fields[0] != name
        end
        nil
      end

      # groupadd/lgroupadd argument list for a brand new group. Desired
      # values that are nil are simply omitted, letting groupadd apply its
      # own defaults. Flag order matches the real module's group_add exactly
      # (live-verified: `groupadd -g 1234 -o -r -K GID_MIN=500 -K GID_MAX=1000
      # g1`): -g gid, then -o (non_unique - only ever meaningful alongside a
      # -g, same nesting real Ansible uses), then -r (system - passed
      # unconditionally on the local path too, lgroupadd accepts it:
      # `lgroupadd -r g1-sys-xyz`), then the -K GID_MIN/GID_MAX pairs.
      #
      # The -K pairs never ride along on the local path - real Ansible
      # refuses gid_min/gid_max + local outright before any command runs
      # (live-verified: "'gid_min' can not be used with 'local'"), and even
      # without that gate its local branch never emits them.
      def self.groupadd_args(
        name : String,
        gid : String?,
        system : Bool,
        non_unique : Bool = false,
        gid_min : String? = nil,
        gid_max : String? = nil,
        local : Bool = false,
      ) : Array(String)
        args = [] of String
        # Every value is single-quoted for the /bin/bash -c it will be
        # embedded in (same posture useradd_args uses) - name: is a
        # task-controlled string and unquoted interpolation let a `$(...)`
        # inside one execute as root.
        if g = gid.presence
          args << "-g #{Shell.single_quote(g)}"
          args << "-o" if non_unique
        end
        args << "-r" if system
        unless local
          args << "-K #{Shell.single_quote("GID_MIN=#{gid_min}")}" if gid_min.presence
          args << "-K #{Shell.single_quote("GID_MAX=#{gid_max}")}" if gid_max.presence
        end
        args << Shell.single_quote(name)
        args
      end

      # groupmod/lgroupmod flags needed to reconcile an existing group with
      # the desired gid. Empty array means nothing to change. -o
      # (non_unique) only ever rides along with a gid that's actually
      # changing - real Ansible nests it inside its own gid-differs branch
      # (live-verified: `groupmod -g 4711 -o root`, and nothing when the
      # gid already matches).
      def self.groupmod_flags(current : Group, desired_gid : String?, non_unique : Bool = false) : Array(String)
        return [] of String if desired_gid.nil? || desired_gid == current.gid
        flags = ["-g #{Shell.single_quote(desired_gid)}"]
        flags << "-o" if non_unique
        flags
      end
    end
  end
end
