#!/usr/bin/env crystal

require "json"
require "random"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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

    SALT_CHARS = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    def execute : PluginResult
      path = @params["path"]?
      return missing_param("path") unless path
      path = expand_tilde(path)

      name = @params["name"]?
      return missing_param("name") unless name

      crypt_scheme = @params["crypt_scheme"]? || @params["hash_scheme"]? || "apr_md5_crypt"
      unless crypt_scheme == "plaintext" || SCHEME_FLAGS.has_key?(crypt_scheme)
        return PluginResult.new(changed: false, failed: true, msg: "Unsupported crypt_scheme: #{crypt_scheme}")
      end

      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)
      create = @params["create"]?.nil? ? true : true?(@params["create"]?)

      unless File.exists?(path)
        return PluginResult.new(changed: false, failed: false, msg: "path not present", path: path) if state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "Destination #{path} does not exist and create=false") unless create
      end

      entries = read_entries(path)

      if state == "absent"
        if entries.delete(name)
          write_entries(path, entries) unless check_mode
          return PluginResult.new(changed: true, failed: false, msg: "Removing user #{name}", path: path)
        else
          return PluginResult.new(changed: false, failed: false, msg: "User #{name} not present", path: path)
        end
      end

      password = @params["password"]?
      return missing_param("password") unless password

      existing_hash = entries[name]?
      new_hash = if existing_hash && unchanged?(password, existing_hash, crypt_scheme)
                   existing_hash
                 else
                   hash = compute_hash(password, crypt_scheme, existing_hash)
                   return PluginResult.new(changed: false, failed: true, msg: "Failed to hash password (is 'openssl' installed?)") unless hash
                   hash
                 end

      content_changed = new_hash != existing_hash
      entries[name] = new_hash
      write_entries(path, entries) if content_changed && !check_mode

      owner = @params["owner"]?
      group = @params["group"]?
      mode = @params["mode"]?
      attrs_changed = false
      if (owner || group || mode) && !check_mode && File.exists?(path)
        before = stat(path)
        apply_owner_group_mode(path, owner, group, mode)
        after = stat(path)
        attrs_changed = attrs_differ?(before, after)
      end

      PluginResult.new(
        changed: content_changed || attrs_changed,
        failed: false,
        msg: content_changed ? "Updating user #{name}" : "User #{name} already present with matching password",
        path: path
      )
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

    private def write_entries(path : String, entries : Hash(String, String))
      File.write(path, entries.map { |name, hash| "#{name}:#{hash}" }.join('\n') + '\n')
    end

    # Recomputes the hash with the salt extracted from `existing_hash`
    # (or, for plaintext, just compares directly) and checks it matches -
    # `openssl passwd`'s own output has no separate "verify" mode, and a
    # fresh random-salt hash would never byte-match a prior one even for
    # the same password.
    private def unchanged?(password : String, existing_hash : String, crypt_scheme : String) : Bool
      return password == existing_hash if crypt_scheme == "plaintext"

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

    private def compute_hash(password : String, crypt_scheme : String, existing_hash : String?) : String?
      return password if crypt_scheme == "plaintext"

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
      String.build do |s|
        len.times { s << SALT_CHARS[Random.rand(SALT_CHARS.size)] }
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
plugin = CrystalPlay::HtpasswdPlugin.new(config)
plugin.run
