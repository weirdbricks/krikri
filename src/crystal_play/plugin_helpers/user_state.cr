module CrystalPlay
  module PluginHelpers
    # UserState - pure logic for parsing `getent passwd` output and
    # deciding what (if anything) needs to change to reconcile a user
    # account with its desired state. No I/O here: the plugin itself calls
    # getent/useradd/etc and hands the results in as plain strings.
    module UserState
      record User, name : String, uid : String, gid : String, comment : String, home : String, shell : String

      # Parses a single `getent passwd <name>` line:
      # "name:password:uid:gid:comment:home:shell"
      def self.parse(line : String) : User?
        fields = line.strip.split(":")
        return nil if fields.size < 7
        User.new(fields[0], fields[2], fields[3], fields[4], fields[5], fields[6])
      end

      # useradd argument list for a brand new account. Desired values that
      # are nil are simply omitted, letting useradd apply its own defaults.
      def self.useradd_args(
        name : String,
        uid : String?,
        gid : String?,
        groups : String?,
        shell : String?,
        home : String?,
        comment : String?,
        system : Bool,
        create_home : Bool,
      ) : Array(String)
        args = [] of String
        args << "-u #{uid}" if uid
        args << "-g #{gid}" if gid
        args << "-G #{groups}" if groups
        args << "-s #{shell}" if shell
        args << "-d #{home}" if home
        args << "-c #{comment.inspect}" if comment
        args << "-r" if system
        args << (create_home ? "-m" : "-M")
        args << name
        args
      end

      # usermod flags needed to reconcile an existing account with the
      # desired attributes. Only attributes that were actually requested
      # (non-nil) and differ from the current value produce a flag.
      def self.usermod_flags(
        current : User,
        uid : String?,
        gid : String?,
        shell : String?,
        home : String?,
        comment : String?,
      ) : Array(String)
        [
          changed_flag("-u", uid, current.uid),
          changed_flag("-g", gid, current.gid),
          changed_flag("-s", shell, current.shell),
          changed_flag("-d", home, current.home),
          comment && comment != current.comment ? "-c #{comment.inspect}" : nil,
        ].compact
      end

      def self.userdel_args(name : String, remove_home : Bool) : Array(String)
        remove_home ? ["-r", name] : [name]
      end

      private def self.changed_flag(flag : String, desired : String?, current : String) : String?
        desired && desired != current ? "#{flag} #{desired}" : nil
      end
    end
  end
end
