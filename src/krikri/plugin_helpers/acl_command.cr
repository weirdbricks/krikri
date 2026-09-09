module Krikri
  module PluginHelpers
    # Command construction + output parsing for the acl plugin (POSIX
    # ACL management via getfacl(1)/setfacl(1)) - split out from
    # plugins/acl.cr so it can be unit-tested without a real ACL-capable
    # filesystem or superuser (mirrors the ufw/iptables split). Every
    # shape here is ported field-for-field from real ansible.posix's own
    # acl.py (build_command/split_entry/build_entry/acl_changed/run_acl)
    # and cross-checked against the actual setfacl 2.3.2 --test output
    # (see spec/unit/acl_command_spec.cr's notes).
    module AclCommand
      # Splits an `entry:` shorthand string into its parts - mirrors
      # real acl.py's split_entry: an optional leading `d`/`default`
      # section (when the entry starts with a 'd') marks a default ACL
      # entry, and an entry with only two ':'-separated sections (the
      # state: absent form, e.g. `user:joe`) gets a nil permissions
      # slot. The etype is normalized by its first letter, exactly like
      # the real module - anything else becomes nil (which then flows
      # through to setfacl as-is and fails there, matching real
      # Ansible's behavior for a garbage entry string).
      def self.split_entry(entry : String) : {Bool?, String?, String?, String?}
        parts = Array(String?).new
        entry.split(':').each { |part| parts << part }
        d = nil
        if entry.downcase.starts_with?('d')
          d = true
          parts.shift
        end

        parts << nil if parts.size == 2

        t = parts[0]?.try(&.downcase)
        e = parts[1]?
        p = parts[2]?

        t = case t
            when .try(&.starts_with?("u")) then "user"
            when .try(&.starts_with?("g")) then "group"
            when .try(&.starts_with?("m")) then "mask"
            when .try(&.starts_with?("o")) then "other"
            else                                nil
            end

        {d, t, e, p}
      end

      # Builds the `-m`/`-x` entry argument - mirrors real acl.py's
      # build_entry. For POSIX ACLs the permissions section is omitted
      # entirely when nil (the state: absent form - `-x user:joe`), for
      # NFSv4 ACLs the 'A' ACE form with the 'tcy' type suffix is built
      # instead, and the group etype gets the 'g' flag in that form.
      def self.build_entry(etype : String?, entity : String?, permissions : String?, use_nfsv4_acls : Bool = false) : String
        if use_nfsv4_acls
          return ["A", etype == "group" ? "g" : "", entity || "", "#{permissions}tcy"].join(':')
        end

        # Empty-string permissions are falsy here exactly like Python's
        # `if permissions:` - a `mask::` entry (mask with an empty
        # qualifier, common in the `entry:` shorthand) must collapse
        # back to `mask:` for the -x/-m form, not keep its empty colon
        # section (real acl.py's own behavior).
        if permissions && !permissions.empty?
          return "#{etype}:#{entity}:#{permissions}"
        end

        "#{etype}:#{entity}"
      end

      # Builds the argv for one getfacl/setfacl invocation - mirrors
      # real acl.py's build_command, including the exact flag ordering
      # real Ansible produces (which matters: `-d` is inserted right
      # after the binary name, and everything else appends). Linux
      # only, matching this engine's Linux-target binaries - the real
      # module's FreeBSD `-h` branch (and its non-Linux fail) is not
      # represented. `mode` is "set" | "rm" | "get".
      def self.build_command(
        mode : String,
        path : String,
        follow : Bool,
        default : Bool,
        recursive : Bool,
        recalculate_mask : String,
        use_nfsv4_acls : Bool = false,
        entry : String = "",
      ) : Array(String)
        if mode == "set"
          cmd = [use_nfsv4_acls ? "nfs4_setfacl" : "setfacl"]
          cmd << (use_nfsv4_acls ? "-a" : "-m") << entry
        elsif mode == "rm"
          cmd = [use_nfsv4_acls ? "nfs4_setfacl" : "setfacl"]
          cmd << "-x" << entry
        else # get
          cmd = [use_nfsv4_acls ? "nfs4_getfacl" : "getfacl"]
          unless use_nfsv4_acls
            # prevents absolute-path warnings and removes headers
            cmd << "--absolute-names" << "--omit-header"
          end
        end

        if recursive && !use_nfsv4_acls
          cmd << "--recursive"
        end

        if recalculate_mask == "mask" && (mode == "set" || mode == "rm")
          cmd << "--mask"
        elsif recalculate_mask == "no_mask" && (mode == "set" || mode == "rm")
          cmd << "--no-mask"
        end

        if !follow && !use_nfsv4_acls
          cmd << "--physical"
        end

        if default
          cmd.insert(1, "-d")
        end

        cmd << path
        cmd
      end

      # run_acl's line filtering, in a pure form (real acl.py drops any
      # line starting with '#', strips each remaining line, then trims a
      # single trailing empty line - blank separator lines BETWEEN
      # entries survive, which is what real Ansible's recursive `acl`
      # return value looks like).
      def self.filter_lines(raw : String) : Array(String)
        lines = [] of String
        raw.each_line do |line|
          lines << line.strip unless line.starts_with?('#')
        end

        lines.pop if !lines.empty? && lines.last.empty?
        lines
      end

      # The idempotency check, ported from real acl.py's acl_changed:
      # `setfacl --test` prints the would-be result of the operation,
      # ending the line with `*,*` when nothing would change and with a
      # full entry list (ending `,*`) when it would. So for POSIX ACLs
      # ANY line that does not end with `*,*` means changed. (FreeBSD's
      # always-true branch is omitted - Linux only, see build_command.)
      # For NFSv4 ACLs the heuristic is different: the tested-new entry
      # is listed twice when it already exists and once when it would
      # genuinely be added.
      def self.changed?(lines : Array(String), entry : String, use_nfsv4_acls : Bool = false) : Bool
        if use_nfsv4_acls
          counter = lines.count { |line| entry == line }
          return counter != 2
        end

        lines.any? { |line| !line.ends_with?("*,*") }
      end
    end
  end
end
