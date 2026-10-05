#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "openssl"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/authorized_keys_file"

module Krikri
  # Authorized_key plugin - manages a public key in a user's
  # ~/.ssh/authorized_keys file
  # Compatible with (a subset of) Ansible's ansible.posix.authorized_key module
  # (this one lives in the ansible.posix collection, not ansible-core)
  #
  # Parameters:
  #   user (required unless path: is given): whose authorized_keys file to edit
  #   key (required): the public key line (options + type + blob + comment)
  #   state (optional): present (default) or absent
  #   path (optional): explicit authorized_keys path, overriding the
  #     user's home-directory default (the user's NSS home + /.ssh/authorized_keys)
  #   manage_dir (optional, default yes): create ~/.ssh (mode 0700) if missing
  class AuthorizedKeyPlugin < BasePlugin
    # Registered key order of the echoed params dict: Ansible's module.params
    # dict starts from the CONTROLLER-SORTED task args (the module-args
    # handoff is serialized with sort_keys, so explicitly-passed params
    # echo alphabetically), then the not-passed params in a fixed order
    # (live-verified vs ansible.posix 2.2.2 / ansible-core 2.19.11 with
    # four different explicit-param subsets, incl. round 992000's
    # user+key+state probes: key, state, user, manage_dir, exclusive,
    # validate_certs, follow, path, key_options, comment). keyfile (the
    # resolved path) follows, then changed; the executor backfills failed
    # last. The stat block add_path_info appends (uid, gid, owner, group,
    # mode, size, with `state` overwritten to the file's kind) lands after
    # changed, exactly like real, since those keys are unlisted here.
    AK_PARAM_DEFAULT_ORDER = ["manage_dir", "state", "exclusive", "validate_certs",
                              "follow", "path", "key_options", "comment"]

    private def result_key_order : Array(String)
      given = @params.keys.select { |k| !k.starts_with?("_ansible_") }.sort!
      order = given.dup
      AK_PARAM_DEFAULT_ORDER.each do |key|
        order << key unless given.includes?(key)
      end
      order << "keyfile" << "changed"
      order
    end

    # The Ansible module's own VALID_SSH2_KEY_TYPES allowlist (ansible.posix
    # authorized_key's parsekey): a new-key line is valid iff one of its
    # whitespace-separated tokens is exactly one of these.
    VALID_SSH2_KEY_TYPES = [
      "sk-ecdsa-sha2-nistp256@openssh.com",
      "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com",
      "webauthn-sk-ecdsa-sha2-nistp256@openssh.com",
      "ecdsa-sha2-nistp256",
      "ecdsa-sha2-nistp256-cert-v01@openssh.com",
      "ecdsa-sha2-nistp384",
      "ecdsa-sha2-nistp384-cert-v01@openssh.com",
      "ecdsa-sha2-nistp521",
      "ecdsa-sha2-nistp521-cert-v01@openssh.com",
      "sk-ssh-ed25519@openssh.com",
      "sk-ssh-ed25519-cert-v01@openssh.com",
      "ssh-ed25519",
      "ssh-ed25519-cert-v01@openssh.com",
      "ssh-dss",
      "ssh-rsa",
      "ssh-xmss@openssh.com",
      "ssh-xmss-cert-v01@openssh.com",
      "rsa-sha2-256",
      "rsa-sha2-512",
      "ssh-rsa-cert-v01@openssh.com",
      "rsa-sha2-256-cert-v01@openssh.com",
      "rsa-sha2-512-cert-v01@openssh.com",
      "ssh-dss-cert-v01@openssh.com",
    ]

    private record PreparedKey, key : String, path : String, key_lines : Array(String)

    private def prepare_key(key : String) : PluginResult | PreparedKey
      if failure = empty_key_result(key)
        return failure
      end

      # Real module's looks_like_url/fetch_file: a key that is a URL
      # (http/https/ftp/file) is fetched first and the fetched body
      # becomes the key material - "invalid key specified: https://..."
      # never happens on Ansible (lucasmaurice.users, jtprogru.hosts).
      key = fetch_url_key(key)
      return PluginResult.new(changed: false, failed: true, msg: @fetch_error) if key.nil?

      # Ansible's keyfile() does a real pwd.getpwnam(user) and
      # hard-fails the task when the user isn't in the passwd DB - it
      # never guesses a home directory for a user that doesn't exist
      # (round 811277, jtprogru.profile: krikri silently invented
      # /home/jtprogru/.ssh/authorized_keys and "succeeded" where real
      # ansible-playbook fails, live-verified).
      if failure = missing_user_result(true?(@params["_ansible_check_mode"]?))
        return failure
      end

      path = resolve_path
      return PluginResult.new(changed: false, failed: true, msg: "Could not determine authorized_keys path: provide 'path' or a valid 'user'") unless path

      # Ansible splits the key into lines, drops blank and
      # '#'-prefixed ones, and hard-fails the task on the FIRST line
      # without a known SSH2 key-type token ("invalid key specified:") -
      # garbage is never silently appended.
      key_lines = new_key_lines(key)
      if failure = invalid_key_result(key_lines)
        return failure
      end

      PreparedKey.new(key, path, key_lines)
    end

    def execute : PluginResult
      key = @params["key"]?
      return missing_param("key") unless key

      prepared = prepare_key(key)
      return prepared if prepared.is_a?(PluginResult)

      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)
      manage_dir = @params["manage_dir"]?.nil? || true?(@params["manage_dir"]?)
      exclusive = true?(@params["exclusive"]?)
      path = prepared.path

      # key_options: replaces whatever options the key line itself
      # carries (the Ansible module's parsed_options overwrite), so the line
      # is rewritten as "<key_options> <type> <blob> <comment>". Both it
      # and the comment param replace fields of the parsed key BEFORE
      # the idempotency comparison, so a difference in either is a real
      # change (real module: parsed_new_key[:4] != existing_keys[blob][:4]).
      key_lines = prepared.key_lines
      if key_options = @params["key_options"]?
        key_lines = key_lines.map { |line| apply_key_options(line, key_options) }
      end
      if comment = @params["comment"]?
        key_lines = key_lines.map { |line| apply_comment(line, comment) }
      end

      original_content = File.exists?(path) ? File.read(path) : ""
      new_content, changed = PluginHelpers::AuthorizedKeysFile.ensure_keys(original_content, key_lines, state == "present", exclusive)

      if error = apply_write(new_content, path, changed, check_mode, manage_dir)
        return error
      end

      # Ansible's own module returns its ENTIRE module.params dict
      # (enforce_state mutates `params` in place and main() does
      # `exit_json(**results)`), with `keyfile` (the resolved keyfile
      # path) and `changed` merged in - so every effective parameter is
      # echoed back, including the ones that were defaulted (manage_dir/
      # exclusive/validate_certs/follow) or absent (comment/key_options/
      # path come through as JSON null). Verified live against
      # ansible.posix.authorized_key 2.1.0 / ansible-core 2.19.
      #
      # Registered key order (live-verified vs ansible-core 2.19.11 +
      # ansible.posix 2.2.2, round 992000 + local container replay): the
      # params dict's own order - key, state, user, manage_dir, exclusive,
      # validate_certs, follow, path, key_options, comment - then keyfile,
      # then changed (only set on the do_write paths), and the executor's
      # failed backfill last. On the already-in-state/idempotent path the
      # module sets NO changed at all, so the executor backfills failed
      # BEFORE changed: that probe registers [..., keyfile, failed,
      # changed] - reproduced by omitting `changed` from the wire result
      # here (the executor's backfill order is failed-then-changed).
      result = PluginResult.new(changed: changed, failed: false, key_order: result_key_order,
        omit_changed: !changed)
      result.extra["user"] = json_string(@params["user"]?)
      result.extra["key"] = JSON::Any.new(key.as(String))
      result.extra["path"] = json_string(@params["path"]?)
      result.extra["keyfile"] = JSON::Any.new(path)
      result.extra["manage_dir"] = JSON::Any.new(manage_dir)
      result.extra["state"] = JSON::Any.new(state)
      result.extra["key_options"] = json_string(@params["key_options"]?)
      result.extra["exclusive"] = JSON::Any.new(exclusive)
      result.extra["comment"] = json_string(@params["comment"]?)
      result.extra["validate_certs"] = JSON::Any.new(@params["validate_certs"]?.nil? || true?(@params["validate_certs"]?))
      result.extra["follow"] = JSON::Any.new(true?(@params["follow"]?))

      # Ansible's AnsibleModule.exit_json runs add_path_info over
      # the result dict: the stat fields appear only because the echoed
      # `path` param (null when not given) points at an existing file -
      # exactly what this mirrors (an absent `path:` param means no stat
      # fields at all, even though the keyfile itself exists).
      add_path_info(result, path) if @params["path"]?

      result
    end

    private def json_string(value : String?) : JSON::Any
      JSON::Any.new(value)
    end

    private URL_PREFIX = /^(http|https|ftp|file):\/\//

    @fetch_error : String = ""

    # Mirrors the Ansible module's fetch_file: file:// reads the local path,
    # http(s):// fetches over the network (validate_certs honored), and a
    # failed fetch is a task failure, never silently treated as key
    # material. ftp:// is not supported by this engine's fetch.
    private def fetch_url_key(key : String) : String?
      return key unless key.strip.matches?(URL_PREFIX)

      url = key.strip
      if url.starts_with?("file://")
        path = url.sub("file://", "")
        begin
          return File.read(path)
        rescue e
          @fetch_error = "Failed to fetch #{url}: #{e.message}"
          return nil
        end
      end

      unless url.starts_with?("http://") || url.starts_with?("https://")
        @fetch_error = "Failed to fetch #{url}: unsupported scheme"
        return nil
      end

      # Kept working (Ansible fetches http:// fine - parity), but a
      # key pulled over cleartext HTTP can be swapped in transit and
      # grant SSH access, so the fetch announces itself loudly.
      if url.starts_with?("http://")
        STDERR.puts "WARNING: fetching authorized key over cleartext HTTP (#{url}) - the key material is not integrity-protected in transit; use HTTPS"
      end

      validate = @params["validate_certs"]?.nil? || true?(@params["validate_certs"]?)
      ctx = OpenSSL::SSL::Context::Client.new
      ctx.verify_mode = validate ? OpenSSL::SSL::VerifyMode::PEER : OpenSSL::SSL::VerifyMode::NONE
      response = HTTP::Client.get(url, tls: url.starts_with?("https://") ? ctx : nil)
      unless response.success?
        @fetch_error = "Failed to fetch #{url}: HTTP #{response.status_code}"
        return nil
      end
      response.body
    rescue e : Socket::Error | IO::Error | OpenSSL::SSL::Error
      @fetch_error = "Failed to fetch #{url}: #{e.message}"
      nil
    end

    # A Ansible playbook can legitimately compute an empty key
    # value at render time (weareinteractive.users' own `key: "{{
    # user.authorized_keys | default([]) | join('\n') }}"`, empty
    # whenever authorized_keys isn't set for that user) - real
    # Ansible's own module treats that as a true no-op (doesn't even
    # create the file), not "add a blank line". Without this,
    # AuthorizedKeysFile#ensure both added a blank line AND could
    # never recognize it as already-present on a rerun (an empty
    # key's signature is nil, and blank lines are filtered out of
    # the "existing lines" list before the signature comparison even
    # runs) - non-idempotent forever, `changed: true` on every run.
    # The Ansible module's new_keys split: blank ("") and '#'-prefixed
    # lines are dropped entirely - not validated, not written.
    private def new_key_lines(key : String) : Array(String)
      key.split("\n").reject { |line| line.empty? || line.starts_with?("#") }
    end

    private def invalid_key_result(key_lines : Array(String)) : PluginResult?
      key_lines.each do |line|
        tokens = line.split
        next if tokens.any? { |token| VALID_SSH2_KEY_TYPES.includes?(token) }

        return PluginResult.new(changed: false, failed: true, msg: "invalid key specified: #{line}")
      end
      nil
    end

    # Strips any inline options (everything before the key-type token)
    # and prefixes the given options, like the Ansible module's serialize
    # step (options are canonicalized to "type blob comment" + options).
    private def apply_key_options(line : String, key_options : String) : String
      tokens = line.split
      type_index = tokens.index { |token| VALID_SSH2_KEY_TYPES.includes?(token) }
      return "#{key_options} #{line}" unless type_index

      "#{key_options} #{tokens[type_index..].join(" ")}"
    end

    # Real module's comment-param overwrite: everything after the blob is
    # the comment, and a given comment: replaces it wholesale.
    private def apply_comment(line : String, comment : String) : String
      tokens = line.split
      type_index = tokens.index { |token| VALID_SSH2_KEY_TYPES.includes?(token) }
      return "#{line} #{comment}" unless type_index && type_index + 1 < tokens.size

      "#{tokens[0..(type_index + 1)].join(" ")} #{comment}"
    end

    private def empty_key_result(key : String) : PluginResult?
      return unless key.strip.empty?

      PluginResult.new(changed: false, failed: false, msg: "No key provided, nothing to do")
    end

    private def resolve_path : String?
      if p = @params["path"]?
        return expand_tilde(p)
      end

      user = @params["user"]?
      return nil unless user

      home = home_directory(user)
      return nil unless home

      File.join(home, ".ssh", "authorized_keys")
    end

    # Ansible's keyfile() does a real pwd.getpwnam(user) lookup and
    # fails the task when the user isn't in the passwd DB - the lookup
    # also feeds the keyfile's uid/gid ownership, so it runs in normal
    # mode even when an explicit path: is given; only check mode +
    # explicit path skips it entirely (keyfile()'s early return).
    # Returns the failure result, or nil when the user exists, no user
    # was given, or the lookup is skipped.
    private def missing_user_result(check_mode : Bool) : PluginResult?
      return unless user = @params["user"]?
      return if check_mode && @params["path"]?
      return if System::User.find_by?(name: user)

      msg = check_mode ? "Either user must exist or you must provide full path to key file in check mode" : "Failed to lookup user #{user}: \"getpwnam(): name not found: '#{user}'\""
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # Resolves a user's home directory natively via System::User
    # (which looks up through NSS, the same source getent reads).
    # Returns nil when the user doesn't exist: Ansible's
    # authorized_key does a real pwd.getpwnam(user) and fails the task
    # rather than guessing /home/<user> for a user that isn't in the
    # passwd DB (round 811277, jtprogru.profile - execute() turns this
    # into the Ansible module's failure before reaching here).
    private def home_directory(user : String) : String?
      sys_user = System::User.find_by?(name: user)
      return unless sys_user

      home = sys_user.home_directory
      return home unless home.empty?

      "/home/#{user}"
    end

    # Ansible's keyfile() creates ONLY the .ssh directory itself
    # (os.mkdir, a single level - a missing grandparent is the exact
    # "Failed to create directory" OSError Ansible fails with, not
    # something to mkdir -p through), then chowns/chmods it 0700
    # unconditionally, even when it already existed. Python's
    # os.path.dirname of a bare relative filename ("9") is "" - NOT
    # Crystal's "." - so an explicit `path: 9`-style path (the type: path
    # spec coerces the native int to "9") has an empty sshdir: manage_dir
    # fails mkdir("") with the "Failed to create directory  : [Errno 2]
    # No such file or directory: ''" fail_json, and manage_dir false hits
    # the keysfile branch's uncaught os.makedirs("") crash, whose bare
    # OSError text IS the whole failure message (live-verified vs
    # 2.19.11).
    private def apply_write(new_content : String, path : String, changed : Bool, check_mode : Bool, manage_dir : Bool) : PluginResult?
      return nil unless changed && !check_mode

      uid, gid = owner_uid_gid
      sshdir = python_dirname(path)
      if manage_dir
        if failure = manage_sshdir(sshdir, uid, gid)
          return failure
        end
      elsif !File.exists?(path) && !Dir.exists?(sshdir)
        if failure = makedirs_basedir(sshdir)
          return failure
        end
      end
      File.write(path, new_content)
      # keyfile()'s tail: chown(keysfile) wrapped in except OSError: pass,
      # then chmod 0600.
      begin
        File.chown(path, uid, gid) unless uid == -1
      rescue File::Error
        # pass
      end
      File.chmod(path, 0o600)
      nil
    end

    # keyfile()'s manage_dir branch: os.mkdir (a single level) when
    # missing, then the UNCAUGHT chown (unlike the keysfile one - a
    # failed chown crashes the module the same way os.mkdir's failure
    # does) and the unconditional chmod 0700, existing dir or not.
    private def manage_sshdir(sshdir : String, uid : Int32, gid : Int32) : PluginResult?
      unless Dir.exists?(sshdir)
        begin
          Dir.mkdir(sshdir)
        rescue e : File::Error
          return PluginResult.new(changed: false, failed: true,
            msg: "Failed to create directory #{sshdir} : #{os_error_text(e, sshdir)}")
        end
      end
      begin
        File.chown(sshdir, uid, gid) unless uid == -1
      rescue e : File::Error
        detail = os_error_text(e, sshdir)
        return PluginResult.new(changed: false, failed: true,
          msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
      end
      File.chmod(sshdir, 0o700)
      nil
    end

    # keyfile()'s basedir branch: os.makedirs (recursive), and an
    # OSError there is NOT fail_json'd - the uncaught crash text alone
    # is the failure message (see mount's makedirs('') twin).
    private def makedirs_basedir(sshdir : String) : PluginResult?
      begin
        FileUtils.mkdir_p(sshdir)
      rescue e : File::Error
        detail = os_error_text(e, sshdir)
        return PluginResult.new(changed: false, failed: true,
          msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
      end
      nil
    end

    # The uid/gid Ansible's keyfile() chowns everything to -
    # pwd.getpwnam(user)'s pw_uid/pw_gid. {-1, -1} (skip the chown) when
    # no user param was given (a path-only call in check mode never
    # reaches here) or the user has no passwd entry.
    private def owner_uid_gid : {Int32, Int32}
      user = @params["user"]?
      if user && (sys_user = System::User.find_by?(name: user))
        {sys_user.id.to_i32, sys_user.group_id.to_i32}
      else
        {-1, -1}
      end
    end

    # Python's os.path.dirname: the head of the last-"/" split - "" when
    # there is no separator at all (Crystal's File.dirname returns "."
    # there, which would silently write a bare relative filename).
    private def python_dirname(path : String) : String
      idx = path.rindex('/')
      return "" unless idx
      return "/" if idx == 0
      path[0...idx]
    end

    # Formats the Errno the way Python's str(OSError) does - that text
    # is exactly what the Ansible module's fail_json message embeds.
    private def os_error_text(e : File::Error, dir : String) : String
      errno = e.os_error.try(&.value)
      case errno
      when  1 then "[Errno 1] Operation not permitted: '#{dir}'"
      when  2 then "[Errno 2] No such file or directory: '#{dir}'"
      when 13 then "[Errno 13] Permission denied: '#{dir}'"
      when 20 then "[Errno 20] Not a directory: '#{dir}'"
      else         "[Errno #{errno}] #{e.message}"
      end
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AuthorizedKeyPlugin.new(config)
plugin.run
