#!/usr/bin/env crystal

require "json"
require "file_utils"
require "system/user"
require "system/group"
require "openssl/digest"
require "./host"
require "./ssh_manager"
require "./local_executor"
require "./plugin_helpers/stat_fields"

module CrystalPlay
  # Plugin result structure with diff support
  class PluginResult
    property changed : Bool
    property failed : Bool
    property msg : String
    property diff : JSON::Any?
    property extra : Hash(String, JSON::Any)
    
    def initialize(
      changed : Bool,
      failed : Bool,
      msg : String,
      diff : JSON::Any? = nil,
      **kwargs
    )
      @changed = changed
      @failed = failed
      @msg = msg
      @diff = diff
      @extra = Hash(String, JSON::Any).new
      kwargs.each do |key, value|
        @extra[key.to_s] = JSON.parse(value.to_json)
      end
    end
    
    def to_json(io : IO)
      result = Hash(String, JSON::Any::Type).new
      result["changed"] = @changed
      result["failed"] = @failed
      result["msg"] = @msg
      
      # Add diff if present
      if diff = @diff
        result["diff"] = diff.raw  # Extract the raw value from JSON::Any
      end
      
      # Add extra fields
      @extra.each do |key, value|
        result[key] = value.raw  # Extract the raw value from JSON::Any
      end
      
      result.to_json(io)
    end
  end
  
  # Base class for all plugins
  abstract class BasePlugin
    property host : Host
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    property config : JSON::Any
    property diff_mode : Bool
    
    def initialize(@config : JSON::Any)
      @host = Host.from_json(@config["host"])
      
      # Parse params
      @params = Hash(String, String).new
      if params_json = @config["params"]?
        params_json.as_h.each do |key, value|
          @params[key] = value.to_s
        end
      end
      
      # Parse vars
      @vars = Hash(String, JSON::Any).new
      if vars_json = @config["vars"]?
        vars_json.as_h.each do |key, value|
          @vars[key] = value
        end
      end
      
      # Check for diff mode
      @diff_mode = is_true?(@params["diff_mode"]?)
    end
    
    # Abstract method - must be implemented by subclasses
    abstract def execute : PluginResult
    
    # Run the plugin and output JSON result
    def run
      puts run_and_capture
    end

    # Same as #run, but returns the JSON result as a String instead of
    # printing it - the piece #run itself needs, and also what the
    # persistent daemon dispatch (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md
    # item #15 - see plugin_daemon.cr) needs: a daemon serves many
    # requests over one long-lived process, so it can never rely on
    # #run's "print to the real STDOUT" behavior - each response has to
    # be framed and written by the daemon loop itself, not by the
    # plugin. Behavior-preserving split: #run is now a one-line wrapper
    # around this, so every existing one-shot call site (every plugin's
    # own driver trailer) is unaffected.
    def run_and_capture : String
      execute.to_json
    rescue ex
      error_result = PluginResult.new(
        changed: false,
        failed: true,
        msg: "Plugin execution failed: #{ex.message}"
      )
      STDERR.puts ex.backtrace.join("\n")
      error_result.to_json
    end
    
    # Helper methods for remote execution
    # Supports both SSH and local connections
    
    # Check if this host should use local connection
    protected def is_local_connection? : Bool
      # Check if ansible_connection is set to local
      if conn = @vars["ansible_connection"]?
        return conn.as_s? == "local"
      end
      
      # Check if host is localhost - "127.0.0.1" is real Ansible's other
      # well-known spelling for the controller itself (see
      # PluginManager.is_local_connection?'s identical fix for the
      # rationale).
      @host.name == "localhost" || @host.name == "127.0.0.1"
    end
    
    # Get the actual hostname to connect to (checks ansible_host variable)
    protected def get_connection_host : String
      # Check for ansible_host variable (overrides inventory hostname)
      if ansible_host = @vars["ansible_host"]?
        return ansible_host.as_s
      end
      
      # Fall back to inventory hostname
      @host.name
    end

    # ansible_ssh_private_key_file, if the inventory specifies one -
    # nil (ssh's own default identity/agent resolution) otherwise.
    protected def get_identity_file : String?
      @vars["ansible_ssh_private_key_file"]?.try(&.as_s?)
    end

    protected def remote_exec(command : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      command = with_environment(command)
      if is_local_connection?
        # Execute locally
        LocalExecutor.exec(command)
      else
        # Execute via SSH - use ansible_host if set
        SSHManager.exec(
          get_connection_host,
          @host.user || "root",
          command,
          @host.port,
          identity_file: get_identity_file
        )
      end
    end

    # Prefixes *command* with `export K='V'; ...` for each entry in the
    # task's `environment:` (real Ansible's per-task env-var keyword,
    # forwarded here as a JSON blob under the `_environment` param key by
    # TaskExecutor#build_plugin_config, already {{ }}-substituted). One
    # shared implementation so every plugin that shells out via
    # #remote_exec gets `environment:` support automatically rather than
    # each plugin needing its own wiring.
    private def with_environment(command : String) : String
      env_json = @params["_environment"]?
      return command unless env_json

      env = Hash(String, String).from_json(env_json)
      return command if env.empty?

      exports = env.map { |key, value| "export #{key}=#{shell_single_quote(value)}" }.join("; ")
      "#{exports}; #{command}"
    end

    # Single-quotes *str* for shell embedding, escaping any embedded
    # single quote - same convention as BatchScript/PluginManager's own
    # copies of this helper (each kept separate rather than shared across
    # unrelated classes).
    private def shell_single_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    protected def remote_upload(local_path : String, remote_path : String)
      if is_local_connection?
        # Just copy locally
        FileUtils.cp(local_path, remote_path)
      else
        SSHManager.upload(
          get_connection_host,
          @host.user || "root",
          local_path,
          remote_path,
          @host.port,
          identity_file: get_identity_file
        )
      end
    end

    protected def remote_download(remote_path : String, local_path : String)
      if is_local_connection?
        # Just copy locally
        FileUtils.cp(remote_path, local_path)
      else
        SSHManager.download(
          get_connection_host,
          @host.user || "root",
          remote_path,
          local_path,
          @host.port,
          identity_file: get_identity_file
        )
      end
    end
    
    protected def remote_file_exists?(path : String) : Bool
      if is_local_connection?
        LocalExecutor.file_exists?(path)
      else
        result = remote_exec("test -f #{path}")
        result[:exit_code] == 0
      end
    end
    
    protected def remote_dir_exists?(path : String) : Bool
      if is_local_connection?
        LocalExecutor.dir_exists?(path)
      else
        result = remote_exec("test -d #{path}")
        result[:exit_code] == 0
      end
    end

    # A native stat()/lstat() syscall (no `stat`/`md5sum`/etc. subprocess
    # spawn) - always operates directly on this process's own filesystem,
    # not through remote_exec's local/SSH split: PluginManager already
    # uploads and executes this same compiled plugin binary directly on
    # the remote host for non-local connections (see
    # execute_remote_plugin), so "the filesystem this process can see" IS
    # the target host's filesystem either way. Returns nil if the path
    # doesn't exist (or isn't statable for some other reason - permission
    # denied, a dangling symlink with follow: true, etc.).
    protected def native_stat(path : String, follow : Bool) : Hash(String, JSON::Any)?
      stat = uninitialized LibC::Stat
      result = follow ? LibC.stat(path, pointerof(stat)) : LibC.lstat(path, pointerof(stat))
      return nil unless result == 0

      # An orphaned uid/gid with no matching /etc/passwd or /etc/group
      # entry resolves to an EMPTY string in real Ansible's own stat
      # (and find's per-file) result, not the stringified numeric id -
      # robertdebock.unowned_files' own `item.pw_name | length == 0`
      # check (and community.general's wider "unowned files" idiom)
      # depends on this exact empty-string convention to detect an
      # orphaned owner/group at all. Falling back to the numeric id
      # (non-empty) meant that check silently never matched anything.
      pw_name = System::User.find_by?(id: stat.st_uid.to_s).try(&.username) || ""
      gr_name = System::Group.find_by?(id: stat.st_gid.to_s).try(&.name) || ""

      PluginHelpers::StatFields.build(
        path,
        mode: stat.st_mode.to_i32,
        size: stat.st_size.to_i64,
        uid: stat.st_uid.to_i64,
        gid: stat.st_gid.to_i64,
        pw_name: pw_name,
        gr_name: gr_name,
        atime: stat.st_atim.tv_sec.to_i64,
        mtime: stat.st_mtim.tv_sec.to_i64,
        ctime: stat.st_ctim.tv_sec.to_i64,
        inode: stat.st_ino.to_i64,
        dev: stat.st_dev.to_i64,
        nlink: stat.st_nlink.to_i64,
      )
    end

    # Native MD5/SHA1/SHA224/SHA256/SHA384/SHA512 file checksum (no
    # `md5sum`/`sha1sum`/`sha256sum` subprocess spawn) - streams the
    # file through OpenSSL's generic EVP digest API rather than loading
    # it fully into memory.
    #
    # Every algorithm other than md5/sha256 used to silently fall
    # through to the `else` branch (SHA1) regardless of what was asked
    # for - get_url:'s own `checksum: "sha384:..."` (geerlingguy.
    # composer's own "Download Composer installer." task, verifying
    # against the officially published installer signature) computed a
    # 40-hex-char SHA1 digest against a 96-hex-char SHA384 expected
    # value, always reporting "checksum mismatch" regardless of whether
    # the download was genuinely correct.
    protected def native_checksum(path : String, algorithm : String) : String
      openssl_name = case algorithm.downcase
                     when "md5"    then "MD5"
                     when "sha1"   then "SHA1"
                     when "sha224" then "SHA224"
                     when "sha256" then "SHA256"
                     when "sha384" then "SHA384"
                     when "sha512" then "SHA512"
                     else               "SHA1"
                     end

      digest = OpenSSL::Digest.new(openssl_name)
      digest.file(path)
      digest.final.hexstring
    end

    # Expands a leading `~` or `~username` the same way Python's own
    # os.path.expanduser does - real Ansible's path-type params go
    # through this before any existence check. geerlingguy.composer's
    # own `composer_home_path: '~/.composer'` default feeds straight
    # into command:'s `creates={{ composer_home_path }}/vendor/{{
    # item.name }}`; checking that literal "~/.composer/vendor/..."
    # string against the filesystem can never match (`~` is not a real
    # path component), so the task reported changed: true on every
    # single run, never converging - a real idempotency bug, not the
    # role's fault (real Ansible's own AnsibleModule expands `~` for
    # every path-type arg, creates/removes/chdir included).
    protected def expand_tilde(path : String) : String
      return path unless path.starts_with?('~')

      rest = path[1..]
      username, _, remainder = rest.partition('/')
      home = if username.empty?
               # Python's own os.path.expanduser checks $HOME FIRST for the
               # bare `~` case, only falling back to the passwd entry if HOME
               # is unset - matches plugin_helpers/mysql_connection.cr's own
               # copy of this same expansion, which already had it right.
               ENV["HOME"]? || System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory)
             else
               System::User.find_by?(name: username).try(&.home_directory)
             end
      return path unless home

      remainder.empty? ? home : File.join(home, remainder)
    end

    # Helper to check if a parameter is truthy
    protected def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end

    # Applies owner/group/numeric mode to a single path natively
    # (`File.chown`/`File.chmod`) instead of shelling to
    # `chown`/`chgrp`/`chmod` - shared by plugins (`apt_repository`,
    # `yum_repository`) that write a single config file and then apply
    # ownership/permissions to it. A *symbolic* mode string (`u+x`) can't
    # be resolved without reimplementing chmod(1)'s symbolic grammar, so
    # it still shells to `chmod` for that one case - see `file.cr`'s own
    # class doc comment for the same trade-off, made first there.
    # Failures (unknown owner/group name, EPERM) are swallowed, matching
    # every prior shell-based version of this logic: none of them checked
    # chown/chgrp/chmod's exit code either.
    protected def apply_owner_group_mode(path : String, owner : String?, group : String?, mode : String?)
      uid = -1
      gid = -1

      if owner
        if user = System::User.find_by?(name: owner)
          uid = user.id.to_i
        end
      end

      if group
        if grp = System::Group.find_by?(name: group)
          gid = grp.id.to_i
        end
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      if mode
        if numeric = mode.to_i?(8)
          File.chmod(path, numeric)
        else
          remote_exec("chmod #{mode} #{path}")
        end
      end
    rescue
    end

    # Generate unified diff
    protected def generate_unified_diff(before : String, after : String, before_header : String = "before", after_header : String = "after") : JSON::Any
      JSON.parse({
        "before" => before,
        "after" => after,
        "before_header" => before_header,
        "after_header" => after_header
      }.to_json)
    end
    
    # Generate attribute diff
    protected def generate_attribute_diff(before : Hash(String, String), after : Hash(String, String)) : JSON::Any
      JSON.parse({
        "before" => before,
        "after" => after
      }.to_json)
    end
  end
end
