#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Getent Plugin - populate a host's fact dict from a system database
  # (passwd, shadow, group, hosts, services, ...), matching
  # ansible.builtin.getent. Registers the result as facts under
  # `getent_<database>` (e.g. getent_passwd, getent_shadow) so later tasks
  # can read `ansible_facts.getent_passwd[user][1]` etc.
  #
  # The parse format is Ansible's: each entry maps to a list of the
  # delimiter-separated fields *after* the key field. For passwd the key is
  # the username and the value is `[password, uid, gid, gecos, home, shell]`,
  # so `getent_passwd["root"][1]` is the UID and `[4]` the home directory -
  # the exact access dev-sec os_hardening makes. Reading the real system DB
  # on the target is a genuine passwd(5)-style parse; unlike the `getent`
  # binary (a libc call), it reads /etc/passwd and /etc/shadow directly as
  # files, which works for the local-database databases Ansible's module
  # targets and avoids forking a subprocess.
  #
  # Parameters (real argument_spec: database/key/service/split/fail_key):
  #   database (required): passwd, shadow, group, or other getent database.
  #   key (optional): a single key, returned as a plain list of its fields
  #     rather than a dict. Lookup follows real getent's per-database
  #     semantics: passwd/group also accept a numeric UID/GID (`getent
  #     passwd 0` -> the root entry, fact keyed by the entry's own first
  #     field), hosts also matches a hostname alias or IP (the fact is
  #     keyed by the line's first field, the address), shadow/gshadow are
  #     username-only (a numeric key there is genuinely not found).
  #     Verified against real getent on this machine.
  #   service (optional): accepted for param parity; see the deliberate-
  #     limits note below.
  #   split (optional): the field delimiter. Real Ansible does NOT always
  #     colon-split: its default is ':' only for passwd/shadow/group/
  #     gshadow (ansible/modules/getent.py's own `colon` list); every
  #     other database splits on runs of whitespace, because that is how
  #     e.g. `getent hosts localhost` ("127.0.0.1  localhost  ip6-...")
  #     and `getent services http` ("http  80/tcp  www") actually emit.
  #     An explicit split: value overrides the default for any database.
  #   fail_key (optional, default true): fail when a requested key is
  #     absent; with false, the key maps to a real JSON null.
  #   check_mode: no-op (getent only reads).
  #
  # Deliberate limit: krikri reads the local database files directly
  # (equivalent to the `files` NSS backend) instead of forking getent, so
  # `service:` cannot redirect a lookup to a non-local NSS backend (ldap,
  # sss, ...): any service value returns the files-backed data. For the
  # overwhelmingly common role usage (`service: files` - pin the lookup
  # to /etc/passwd et al. and bypass LDAP/SSSD) this is exactly right.
  class GetentPlugin < BasePlugin
    # Databases real Ansible colon-splits by default; everything else
    # (hosts, services, protocols, ...) splits on runs of whitespace.
    private COLON_DATABASES = ["passwd", "shadow", "group", "gshadow"]

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

      # `service:` is accepted (real Ansible passes it to getent as `-s`,
      # which GNU getopt reorders so it works even positioned after the
      # database/key) but deliberately not acted on: this plugin's data
      # source is always the local files backend - see the class comment.
      # (Referencing the param documents that it is consumed, not dropped.)
      @params["service"]?

      # Real Ansible's split default: ':' only for the four colon-databases;
      # whitespace runs for everything else (ansible/modules/getent.py).
      split = @params["split"]?
      if split.nil? && COLON_DATABASES.includes?(database)
        split = ":"
      end

      entries = parse_database(file, database, split)

      key = @params["key"]?
      facts = Hash(String, JSON::Any).new

      fail_key = @params["fail_key"]? ? true?(@params["fail_key"]) : true

      if key
        # Real `getent <db> <key>` emits only the FIRST matching line - a
        # duplicated key's second line (tcp+udp service pairs) is merged
        # into a list-of-lists only on enumeration, never on a keyed
        # lookup (live-verified: real `getent services domain` ->
        # ["53/tcp"], real enumeration -> [["53/tcp"], ["53/udp"]]). So
        # the keyed branch scans for the first matching line instead of
        # reading the merged enumeration value.
        value = nil
        if resolved = resolve_key(file, database, split, key)
          matched_key, fields = resolved
          value = JSON::Any.new(fields.map { |field| JSON::Any.new(field) })
          key = matched_key
        end
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
        # Single-key lookup still wraps the result in a dict keyed by
        # *key* (a one-entry version of the no-key branch below), NOT a
        # bare field-list - real Ansible's own `getent_passwd` fact is
        # always `{"root": ["x", "0", "0", ...]}`, even for a single-key
        # lookup, so a role's own `getent_passwd[username]` indexing
        # (robertdebock.git's/.users' own `getent_passwd[git_username]
        # != none` existence check) always resolved to the whole
        # (unindexable-by-username) field list itself here instead of
        # the one real field-list entry, or "undefined" once #[] failed
        # to find an integer index - either way, `!= none` never behaved
        # the way the role's author intended.
        #
        # A key not found with fail_key: false must map to a real JSON
        # null, not an empty array - real Ansible's own getent module
        # sets the value to None in that case (verified against its own
        # source), and `getent_passwd[key] == none` is exactly how a
        # role decides "this user doesn't exist yet, create it" (found
        # via filviu.activemq/.tomcat's own "env | determine if <user>
        # exists" -> "setup | create system user" pair, `when: getent_
        # passwd[user] == none`). An empty array `!= none` under real
        # Python/Jinja equality (arrays and None are never equal
        # regardless of emptiness), so that `when:` always evaluated
        # false and the user-creation task was silently skipped every
        # single run, cascading into "chown failed: failed to look up
        # user X" on every later task that assumed the user existed.
        value_fact = value || JSON::Any.new(nil)
        facts["getent_#{database}"] = JSON::Any.new({key => value_fact})
      else
        facts["getent_#{database}"] = JSON::Any.new(entries)
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

    # Key resolution for a single-key lookup: the first line whose first
    # field equals the key wins (real `getent <db> <key>` emits only the
    # first match); beyond that, passwd/group also accept a numeric
    # UID/GID and non-colon databases match any field on the line (a
    # hosts alias), mirroring real getent's per-database lookup (verified
    # live: `getent passwd 0` -> root's entry, `getent hosts localhost`
    # -> the 127.0.0.1 line, `getent shadow 0` -> rc 2 not-found).
    # Returns the matched entry's first field (the real fact key) and its
    # remaining fields.
    private def resolve_key(file : String, database : String, split : String?, key : String) : {String, Array(String)}?
      numeric = key.matches?(/\A\d+\Z/)
      colon = COLON_DATABASES.includes?(database)

      begin
        File.read_lines(file).each do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          line = line.split("#").first.strip unless colon
          fields = split ? line.split(split) : line.split
          next if fields.empty?
          first = fields.shift
          return {first, fields} if first == key
          if (database == "passwd" || database == "group") && numeric
            return {first, fields} if fields[1]? == key
          elsif !colon && fields.includes?(key)
            return {first, fields}
          end
        end
      rescue
      end

      nil
    end

    # Parse a database file into {key => fields...} JSON, where key is the
    # first field and the value keeps the remaining fields, split on the
    # given delimiter (nil = runs of whitespace, matching Python's
    # str.split(None) - the real module's default for non-colon
    # databases). This matches Ansible's getent output shape. Comments and
    # blank lines are skipped.
    #
    # A key appearing more than once (e.g. a service listed for both tcp
    # and udp in /etc/services) becomes a list of field-lists, matching
    # real Ansible's 2.11+ enumeration handling rather than silently
    # keeping only the last line.
    private def parse_database(file : String, database : String, split : String?) : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new
      colon = COLON_DATABASES.includes?(database)

      begin
        File.read_lines(file).each do |line|
          line = line.strip
          next if line.empty? || line.starts_with?("#")
          # Non-colon database files carry trailing comments ("domain
          # 53/tcp # Domain Name Server") that real getent's output never
          # has - the libc files backend strips them, so krikri must too
          # (colon-database values like a gecos field may legitimately
          # contain '#', so those are not touched).
          line = line.split("#").first.strip unless colon
          fields = split ? line.split(split) : line.split
          next if fields.empty?
          key = fields.shift
          value = JSON::Any.new(fields.map { |field| JSON::Any.new(field) })
          if existing = result[key]?
            if existing.as_a[0]?.try(&.raw.is_a?(Array))
              result[key] = JSON::Any.new(existing.as_a + [value])
            else
              result[key] = JSON::Any.new([existing, value])
            end
          else
            result[key] = value
          end
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
plugin = Krikri::GetentPlugin.new(config)
plugin.run
