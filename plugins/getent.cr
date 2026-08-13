#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Getent Plugin - populate a host's fact dict from a system database
  # (passwd, shadow, group, hosts, services, ...), matching
  # ansible.builtin.getent. Registers the result as facts under
  # `getent_<database>` (e.g. getent_passwd, getent_shadow) so later tasks
  # can read `ansible_facts.getent_passwd[user][1]` etc.
  #
  # The parse format is Ansible's: each entry maps to a list of the
  # colon-separated fields *after* the key field. For passwd the key is the
  # username and the value is `[password, uid, gid, gecos, home, shell]`, so
  # `getent_passwd["root"][1]` is the UID and `[4]` the home directory -
  # the exact access dev-sec os_hardening makes. Reading the real system DB
  # on the target is a genuine passwd(5)-style parse; unlike the `getent`
  # binary (a libc call), it reads /etc/passwd and /etc/shadow directly as
  # files, which works for the local-database databases Ansible's module
  # targets and avoids forking a subprocess.
  #
  # Parameters:
  #   database (required): passwd, shadow, group, or other getent database.
  #   key (optional): a single key, returned as a plain list of its fields
  #     rather than a dict.
  #   check_mode: no-op (getent only reads).
  class GetentPlugin < BasePlugin
    def execute : PluginResult
      database = @params["database"]?
      unless database
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: database"
        )
      end

      file = database_file(database)
      unless file
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported getent database: #{database}"
        )
      end

      unless File.exists?(file)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Could not find a matching entry: #{database} (#{file})"
        )
      end

      entries = parse_database(file, database)

      key = @params["key"]?
      facts = Hash(String, JSON::Any).new

      fail_key = @params["fail_key"]? ? is_true?(@params["fail_key"]) : true

      if key
        value = entries[key]?
        if !value && fail_key
          # Real Ansible's getent module fails outright when a specific
          # key isn't found (fail_key: true is its own default) - a
          # single-key lookup on a nonexistent entry previously
          # succeeded here by silently falling back to the whole
          # dict, so a role's own `rescue:` block gated on this
          # exact failure (robertdebock.users' "Get or set the home
          # directory", used to fall back to /home for a to-be-removed
          # user) never triggered.
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "One or more supplied key could not be found in the database."
          )
        end
        # Single-key lookup returns just that entry's field list (empty
        # when not found and fail_key: false suppressed the failure
        # above).
        facts["getent_#{database}"] = JSON::Any.new((value || [] of String).map { |field| JSON::Any.new(field) })
      else
        dict = Hash(String, JSON::Any).new
        entries.each { |k, v| dict[k] = JSON::Any.new(v.map { |field| JSON::Any.new(field) }) }
        facts["getent_#{database}"] = JSON::Any.new(dict)
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "Successfully retrieved #{database} database",
        ansible_facts: JSON::Any.new(facts)
      )
    end

    # Map a database name to the local file it reads. passwd/shadow/group
    # are the ones os_hardening uses; the others are accepted for
    # completeness but real Ansible reads them via libc NSS so the exact
    # backing store varies by platform.
    private def database_file(database : String) : String?
      case database
      when "passwd"    then "/etc/passwd"
      when "shadow"    then "/etc/shadow"
      when "group"     then "/etc/group"
      when "gshadow"   then "/etc/gshadow"
      when "hosts"     then "/etc/hosts"
      when "services"  then "/etc/services"
      when "protocols" then "/etc/protocols"
      when "networks"  then "/etc/networks"
      when "aliases"   then "/etc/aliases"
      when "rpc"       then "/etc/rpc"
      else                  nil
      end
    end

    # Parse a colon-delimited database into {key => [fields...]}, where key
    # is the first field and the value keeps the remaining fields. This
    # matches Ansible's getent output shape. Comments and blank lines are
    # skipped.
    private def parse_database(file : String, database : String) : Hash(String, Array(String))
      result = Hash(String, Array(String)).new

      begin
        File.read_lines(file).each do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          fields = line.split(":")
          next if fields.empty?
          key = fields.shift
          result[key] = fields
        end
      rescue
        # Missing/unreadable file: leave the result empty rather than fail
        # the whole task (a DB may legitimately be absent on some hosts).
      end

      result
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::GetentPlugin.new(config)
plugin.run
