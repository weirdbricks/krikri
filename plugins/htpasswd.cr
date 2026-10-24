#!/usr/bin/env crystal

require "json"
require "random"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/file_attrs"
require "../src/krikri/plugin_helpers/python_lib_gate"

module Krikri
  # Htpasswd plugin - manages entries in an Apache-style htpasswd file
  # Compatible with (a subset of) community.general.htpasswd
  #
  # Parameters:
  #   path (required): the htpasswd file
  #   name (required): username to add/update/remove
  #   password (required for state: present): plaintext password to hash
  #   crypt_scheme (optional, aliases: hash_scheme; default apr_md5_crypt):
  #     apr_md5_crypt, md5_crypt, sha256_crypt, sha512_crypt, or plaintext
  #   state (optional, default present): present or absent
  #   create (optional, default true): create path if it doesn't exist
  #   owner / group / mode (optional): applied to path after writing
  #
  # Hashing shells out to `openssl passwd` (present on every real target
  # this engine has hit so far) rather than reimplementing apr1/md5-crypt's
  # bit-level algorithm natively - the same shell-to-a-trusted-system-tool
  # trade-off `user:`'s own module doc already documents for password
  # hashes in general. The password is piped via stdin (`-stdin`), never
  # passed as an argv element, so it never shows up in `ps`.
  class HtpasswdPlugin < BasePlugin
    SCHEME_FLAGS = {
      "apr_md5_crypt" => "-apr1",
      "apr1"          => "-apr1",
      "md5_crypt"     => "-1",
      "md5"           => "-1",
      "sha256_crypt"  => "-5",
      "sha512_crypt"  => "-6",
    }

    include PluginHelpers::FileAttrs

    SALT_CHARS = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    # Schemes this engine can actually produce on a target: openssl
    # passwd's four algorithms plus plaintext and the unsalted
    # ldap_sha1 (see #ldap_sha1_hash). Everything else Ansible accepts is
    # a real passlib handler with no openssl equivalent.
    COMPUTABLE_SCHEMES = (SCHEME_FLAGS.keys + ["plaintext", "ldap_sha1"]).map(&.downcase)

    # The four apache_hashes passlib's own htpasswd_context always
    # carries (htpasswd.py's module-level list) plus every other passlib
    # handler name Ansible accepts. Verified against community.general
    # 13.2.0's htpasswd.py + passlib's own handler registry.
    APACHE_HASHES = ["apr_md5_crypt", "des_crypt", "ldap_sha1", "plaintext"]

    PASSLIB_ONLY_SCHEMES = [
      "argon2", "atlassian_pbkdf2_sha1", "bcrypt", "bcrypt_sha256",
      "bigcrypt", "bsd_nthash", "bsdi_crypt", "cisco_asa", "cisco_pix",
      "cisco_type7", "crypt16", "cta_pbkdf2_sha1", "django_argon2",
      "django_bcrypt", "django_bcrypt_sha256", "django_des_crypt",
      "django_disabled", "django_pbkdf2_sha1", "django_pbkdf2_sha256",
      "django_salted_md5", "django_salted_sha1", "dlitz_pbkdf2_sha1",
      "fshp", "grub_pbkdf2_sha512", "hex_md4", "hex_md5", "hex_sha1",
      "hex_sha256", "hex_sha512", "htdigest", "ldap_bcrypt",
      "ldap_bsdi_crypt", "ldap_des_crypt", "ldap_hex_md5", "ldap_hex_sha1",
      "ldap_md5", "ldap_md5_crypt", "ldap_pbkdf2_sha1",
      "ldap_pbkdf2_sha256", "ldap_pbkdf2_sha512", "ldap_plaintext",
      "ldap_salted_md5", "ldap_salted_sha1", "ldap_salted_sha256",
      "ldap_salted_sha512", "ldap_sha1_crypt", "ldap_sha256_crypt",
      "ldap_sha512_crypt", "lmhash", "md5_crypt", "msdcc", "msdcc2",
      "mssql2000", "mssql2005", "mysql323", "mysql41", "nthash",
      "oracle10", "oracle11", "pbkdf2_sha1", "pbkdf2_sha256",
      "pbkdf2_sha512", "phpass", "postgres_md5", "roundup_plaintext",
      "scram", "scrypt", "sha1_crypt", "sha256_crypt", "sha512_crypt",
      "sun_md5_crypt", "unix_disabled", "unix_fallback",
    ]

    # every passlib name this plugin answers to, lowercase - the lookup
    # Ansible does is case-insensitive (passlib lowercases the scheme).
    KNOWN_SCHEMES = (APACHE_HASHES + SCHEME_FLAGS.keys + PASSLIB_ONLY_SCHEMES).map(&.downcase)

    def execute : PluginResult
      path = @params["path"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      name = @params["name"]?
      return missing_param("name") unless name

      crypt_scheme = (@params["crypt_scheme"]? || @params["hash_scheme"]? || "apr_md5_crypt").downcase

      # htpasswd.py imports passlib at module level and fails right after
      # argspec validation - before the state/path logic, so state=absent
      # fails too - when the target's Python lacks it, even though this
      # native plugin never needs it. Observed on a target without passlib.
      if gate = Krikri.missing_python_library("passlib", "passlib.apache")
        return PluginResult.new(changed: false, failed: true, msg: gate[:msg])
      end

      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)
      create = @params["create"]?.nil? ? true : true?(@params["create"]?)

      # Real htpasswd.py's order, in full: main() strips blank lines
      # from an existing path FIRST (an unreadable path there is
      # swallowed by `except OSError: pass`), then dispatches to
      # present() - which builds the CryptContext, i.e. is where an
      # unknown hash_scheme blows up - and only then looks at the
      # destination's existence. absent() never builds a context, so
      # it never validates hash_scheme at all. Live-verified against
      # 2.19.11: state=present + unknown scheme beats both
      # create=false and a directory path; state=absent does not
      # validate the scheme.
      if res = preflight_failure(path, state, create, crypt_scheme)
        return res
      end

      file_existed = File.exists?(path)

      entries = read_entries(path)

      if state == "absent"
        msg, content_changed = remove_user(path, name, entries, check_mode)
      else
        upsert = upsert_user(path, name, entries, crypt_scheme, file_existed, check_mode)
        return upsert if upsert.is_a?(PluginResult)
        msg, content_changed = upsert
      end

      # check_file_attrs() -> set_fs_attributes_if_different, which runs
      # on BOTH the present and absent paths and FAILS the task on a
      # rejected chown/chgrp exactly like ini_file's own tail (kpg32
      # seed 32).
      attrs_changed, failure = apply_file_attrs(path, check_mode)
      return failure if failure

      finish(msg, path, content_changed, attrs_changed)
    end

    # The three failure checks real reaches before it ever reads or
    # writes the destination, in Ansible's own order.
    private def preflight_failure(path : String, state : String, create : Bool, crypt_scheme : String) : PluginResult?
      return unknown_scheme_result(crypt_scheme) if state == "present" && !known_scheme?(crypt_scheme)
      missing_file_result(path, state, create) || read_error_result(path)
    end

    private def known_scheme?(scheme : String) : Bool
      KNOWN_SCHEMES.includes?(scheme)
    end

    # The state=present body: verify/hash the password, then upsert the
    # entry. Returns {msg, content_changed} on success, PluginResult when
    # real present() would have failed the task before any attrs work.
    private def upsert_user(path : String, name : String, entries : Hash(String, String),
                            crypt_scheme : String, file_existed : Bool, check_mode : Bool) : {String, Bool} | PluginResult
      password = @params["password"]?
      # passlib's HtpasswdFile.verify is reached with None and raises
      # this - real htpasswd.py's `password` is NOT a required arg, so
      # there is no argspec-level "missing required arguments" error to
      # reach instead. New-file and existing-file paths both land here.
      return nil_secret_result unless password

      existing_hash = entries[name]?
      new_hash = target_hash(password, existing_hash, crypt_scheme)
      return new_hash if new_hash.is_a?(PluginResult)

      write_res = write_updated(path, name, entries, new_hash, existing_hash, check_mode)
      return write_res if write_res.is_a?(PluginResult)
      content_changed = write_res
      msg = upsert_msg(path, name, content_changed, file_existed, check_mode)
      {msg, content_changed}
    end

    # passlib's CryptContext(schemes=[scheme] + apache_hashes) raises
    # a ValueError whose str() is the algorithm name wrapped in BOTH
    # the module's own double quotes and Python's repr single quotes -
    # reproduced verbatim here (the extra double quotes are real, not a
    # krikri artifact; verified against the passlib output itself).
    private def unknown_scheme_result(crypt_scheme : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: %("no crypt handler found for algorithm: '#{crypt_scheme}'"))
    end

    private def nil_secret_result : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "secret must be unicode or bytes, not None")
    end

    # A directory where the htpasswd file should be: Ansible's HtpasswdFile
    # opens it and Python's open() raises IsADirectoryError, which
    # htpasswd.py's outer `except Exception as e: fail_json(msg=f"{e}")`
    # renders with the errno prefix.
    private def read_error_result(path : String) : PluginResult?
      return nil unless File.exists?(path) && File.info?(path).try(&.directory?)

      PluginResult.new(changed: false, failed: true,
        msg: "[Errno 21] Is a directory: '#{path}'")
    end

    # Ansible branches the present-path msg on whether this call
    # actually created the file (its own present() says "Created {path}
    # and added {user}" for a brand-new file, "Add/update {user}" for a
    # change to an existing one) - a brand-new create is not an "update".
    private def upsert_msg(path : String, name : String, content_changed : Bool,
                           file_existed : Bool, check_mode : Bool) : String
      if content_changed && !file_existed
        check_mode ? "Create #{path}" : "Created #{path} and added #{name}"
      elsif content_changed
        "Add/update #{name}"
      else
        "#{name} already present"
      end
    end

    # Real absent(): "{user} not present" when the entry isn't there,
    # "Remove {user}" when it is.
    private def remove_user(path : String, name : String, entries : Hash(String, String), check_mode : Bool) : {String, Bool}
      if entries.delete(name)
        write_entries(path, entries) unless check_mode
        {"Remove #{name}", true}
      else
        {"#{name} not present", false}
      end
    end

    # check_file_attrs() appends its own clause to the msg whenever the
    # owner/group/mode had to be fixed - including its missing-space
    # quirk on the not-changed branch ("u already presentownership,
    # perms or SE linux context changed"), which is what Ansible prints.
    private def finish(msg : String, path : String, content_changed : Bool, attrs_changed : Bool) : PluginResult
      msg += if content_changed
               " and ownership, perms or SE linux context changed"
             else
               "ownership, perms or SE linux context changed"
             end if attrs_changed

      # Ansible 2.19.11 registered order (live-verified, `{{ r | to_json }}`
      # on create/rerun/update/remove): msg, changed - exit_json(msg=...,
      # changed=...), and NO path key in the result (the path only exists
      # as the task's input parameter).
      PluginResult.new(
        changed: content_changed || attrs_changed,
        failed: false,
        msg: msg,
        key_order: %w[msg changed]
      )
    end

    private def missing_file_result(path : String, state : String, create : Bool) : PluginResult?
      return nil if File.exists?(path)
      return PluginResult.new(changed: false, failed: false, msg: "path not present", key_order: %w[msg changed]) if state == "absent"
      # present() raises ValueError(f"Destination {dest} does not exist")
      # - no ", and create=false" tail.
      return PluginResult.new(changed: false, failed: true, msg: "Destination #{path} does not exist") unless create
      nil
    end

    private def target_hash(password : String, existing_hash : String?, crypt_scheme : String) : PluginResult | String
      return existing_hash if existing_hash && unchanged?(password, existing_hash, crypt_scheme)
      unless COMPUTABLE_SCHEMES.includes?(crypt_scheme)
        # A real passlib handler name this engine has no `openssl passwd`
        # equivalent for (bcrypt, pbkdf2_sha256, scrypt, ...). Real
        # hashes it; here it cannot, so say which scheme is out of reach
        # rather than mislabelling a known algorithm as unsupported.
        return PluginResult.new(changed: false, failed: true,
          msg: "Unsupported crypt_scheme: #{crypt_scheme}")
      end
      hash = compute_hash(password, crypt_scheme, existing_hash)
      return PluginResult.new(changed: false, failed: true, msg: "Failed to hash password (is 'openssl' installed?)") unless hash
      hash
    end

    private def write_updated(path : String, name : String, entries : Hash(String, String),
                              new_hash : String, existing_hash : String?, check_mode : Bool) : Bool | PluginResult
      content_changed = new_hash != existing_hash
      entries[name] = new_hash
      if content_changed && !check_mode
        # Real present() makedirs's dirname(dest) exactly in the
        # destination-does-not-exist branch, right before HtpasswdFile(new=True)
        # opens the file - so a missing parent directory is created and the
        # task succeeds. The sibling branches can't reach this: state=absent
        # and create=false exited in preflight, and check_mode returned
        # "Create <path>" before ever touching the tree.
        unless File.exists?(path)
          if failure = create_missing_directories(path)
            return failure
          end
        end
        write_entries(path, entries)
      end
      content_changed
    end

    # htpasswd.py's create_missing_directories(dest): os.makedirs of
    # dirname(dest) (recursive, only when missing), with its OSError
    # caught by main()'s outer `except Exception: fail_json(msg=to_native(e))`
    # - i.e. the bare Python errno text IS the failure msg (live-verified
    # against 2.19.11: a missing parent dir is created silently, and a
    # bare-relative `path: passwdfile` still fails with "[Errno 2] No such
    # file or directory: ''" because os.path.dirname gives "" there).
    private def create_missing_directories(path : String) : PluginResult?
      dir = python_dirname(path)
      return PluginResult.new(changed: false, failed: true,
        msg: "[Errno 2] No such file or directory: ''") if dir.empty?
      return nil if Dir.exists?(dir)
      begin
        FileUtils.mkdir_p(dir)
      rescue e : File::Error
        PluginResult.new(changed: false, failed: true,
          msg: os_error_text(e, first_missing_component(dir) || dir))
      end
    end

    # The first path down the tree that does not exist at all. Python's
    # os.makedirs recursion creates parents shallow-first, so its mkdir
    # raises (and the errno text names) the shallowest uncreatable
    # component, not the destination; a failure on an intermediate that
    # only exists as a FILE surfaces the deeper child instead, exactly
    # how a manual level-by-level walk reports it.
    private def first_missing_component(dir : String) : String?
      parts = dir.split('/').reject(&.empty?)
      return nil if parts.empty?
      cursor = dir.starts_with?('/') ? "/" : ""
      parts.each do |part|
        cursor = cursor.empty? || cursor.ends_with?('/') ? cursor + part : "#{cursor}/#{part}"
        return cursor unless File.exists?(cursor) || Dir.exists?(cursor)
      end
      nil
    end

    # Python's os.path.dirname: the head of the last-"/" split - "" when
    # there is no separator at all (Crystal's File.dirname returns "."
    # there, which would make the bare-relative path silently succeed
    # with a mkdir_p(".") that the real module crashes on). Same helper
    # reasoning as authorized_key's copy.
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
      when 17 then "[Errno 17] File exists: '#{dir}'"
      when 20 then "[Errno 20] Not a directory: '#{dir}'"
      else         "[Errno #{errno}] #{e.message}"
      end
    end

    private def read_entries(path : String) : Hash(String, String)
      entries = Hash(String, String).new
      return entries unless File.exists?(path)

      File.read(path).each_line do |line|
        line = line.strip
        next if line.empty?
        parts = line.split(':', 2)
        next unless parts.size == 2
        entries[parts[0]] = parts[1]
      end
      entries
    end

    private def write_entries(path : String, entries : Hash(String, String)) : Nil
      File.write(path, entries.map { |name, hash| "#{name}:#{hash}" }.join('\n') + '\n')
    end

    # Recomputes the hash with the salt extracted from `existing_hash`
    # (or, for plaintext, just compares directly) and checks it matches -
    # `openssl passwd`'s own output has no separate "verify" mode, and a
    # fresh random-salt hash would never byte-match a prior one even for
    # the same password.
    private def unchanged?(password : String, existing_hash : String, crypt_scheme : String) : Bool
      return password == existing_hash if crypt_scheme == "plaintext"
      return existing_hash == ldap_sha1_hash(password) if crypt_scheme == "ldap_sha1"

      salt = extract_salt(existing_hash)
      return false unless salt

      recomputed = compute_hash(password, crypt_scheme, existing_hash)
      recomputed == existing_hash
    end

    private def extract_salt(existing_hash : String) : String?
      parts = existing_hash.split('$')
      return nil if parts.size < 4
      parts[2]
    end

    # ldap_sha1 is one of the four apache_hashes passlib's htpasswd
    # context always carries, so Ansible accepts it everywhere - and it is
    # unsalted, which makes it the one non-plaintext scheme computable
    # here without shelling out at all.
    private def ldap_sha1_hash(password : String) : String
      "{SHA}" + Base64.strict_encode(Digest::SHA1.digest(password))
    end

    private def compute_hash(password : String, crypt_scheme : String, existing_hash : String?) : String?
      return password if crypt_scheme == "plaintext"
      return ldap_sha1_hash(password) if crypt_scheme == "ldap_sha1"

      flag = SCHEME_FLAGS[crypt_scheme]
      salt_len = (crypt_scheme == "sha256_crypt" || crypt_scheme == "sha512_crypt") ? 16 : 8
      salt = (existing_hash && extract_salt(existing_hash)) || random_salt(salt_len)

      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("openssl", ["passwd", flag, "-salt", salt, "-stdin"],
        input: IO::Memory.new(password), output: output, error: error)
      return nil unless status.success?

      output.to_s.strip
    rescue
      nil
    end

    private def random_salt(len : Int32) : String
      String.build do |str|
        len.times { str << SALT_CHARS[Random::Secure.rand(SALT_CHARS.size)] }
      end
    end

    private def stat(path : String) : LibC::Stat?
      s = uninitialized LibC::Stat
      result = LibC.stat(path, pointerof(s))
      result == 0 ? s : nil
    end

    private def attrs_differ?(before : LibC::Stat?, after : LibC::Stat?) : Bool
      return false unless before && after
      before.st_uid != after.st_uid || before.st_gid != after.st_gid || (before.st_mode & 0o7777) != (after.st_mode & 0o7777)
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::HtpasswdPlugin.new(config)
plugin.run
