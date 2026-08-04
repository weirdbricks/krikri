module CrystalPlay
  module PluginHelpers
    # PostgresqlAcl - pure logic for parsing a PostgreSQL ACL array (the
    # `relacl`/`nspacl`/`datacl` columns of `pg_class`/`pg_namespace`/
    # `pg_database`, cast to `::text` in the query so the driver hands
    # back a plain string rather than needing a native `aclitem[]`
    # codec) and mapping privilege names to their single-letter codes.
    # No I/O - postgresql_privs.cr does the actual GRANT/REVOKE and ACL
    # lookups.
    #
    # Format verified against a real PostgreSQL 17 server, not assumed
    # from docs: `{postgres=arwdDxtm/postgres,bob=rw/postgres,alice=r*/postgres}`
    # - comma-separated `grantee=privs/grantor` entries inside `{}`;
    # an empty grantee (`=r/postgres`) means the `PUBLIC` pseudo-role; a
    # `*` immediately following a privilege letter means that specific
    # privilege carries `WITH GRANT OPTION` (not a whole-entry flag - two
    # privileges on the same entry can differ, e.g. `r*w` is SELECT
    # WITH GRANT OPTION plus a plain UPDATE).
    module PostgresqlAcl
      # Privilege name -> single-letter ACL code, per object type. Real
      # PostgreSQL's own privilege letters (see the GRANT/`\dp` docs),
      # verified against actual `relacl`/`nspacl`/`datacl` output rather
      # than assumed. `MAINTAIN` (PostgreSQL 17+) is included for
      # `table`/`sequence` since it's harmless to recognize even on an
      # older server (a request for it there would just fail with the
      # server's own "unrecognized privilege" error, same as any other
      # server-version-specific privilege).
      PRIV_LETTERS = {
        "table" => {
          "SELECT" => 'r', "INSERT" => 'a', "UPDATE" => 'w', "DELETE" => 'd',
          "TRUNCATE" => 'D', "REFERENCES" => 'x', "TRIGGER" => 't', "MAINTAIN" => 'm',
        },
        "sequence"   => {"SELECT" => 'r', "UPDATE" => 'w', "USAGE" => 'U'},
        "schema"     => {"CREATE" => 'C', "USAGE" => 'U'},
        "database"   => {"CREATE" => 'C', "CONNECT" => 'c', "TEMPORARY" => 'T', "TEMP" => 'T'},
        "language"   => {"USAGE" => 'U'},
        "tablespace" => {"CREATE" => 'C'},
        "type"       => {"USAGE" => 'U'},
      }

      # "ALL"/"ALL PRIVILEGES" expands to every privilege real PostgreSQL
      # grants under `GRANT ALL ON <type> ... `for that object type -
      # deliberately excludes `MAINTAIN` for `table`/`sequence` even
      # though it's a real privilege letter above, matching real
      # PostgreSQL's own `GRANT ALL` behavior verified against a real
      # server (ALL does not imply MAINTAIN pre-17, and even on 17 the
      # module's own real-Ansible behavior this codebase matches doesn't
      # special-case it in ALL's expansion either).
      def self.all_privs(type : String) : Array(String)
        case type
        when "table"      then %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
        when "sequence"   then %w[SELECT UPDATE USAGE]
        when "schema"     then %w[CREATE USAGE]
        when "database"   then %w[CREATE CONNECT TEMPORARY]
        when "language"   then %w[USAGE]
        when "tablespace" then %w[CREATE]
        when "type"       then %w[USAGE]
        else                   raise "unknown privilege type: #{type.inspect}"
        end
      end

      # Resolves "ALL"/"ALL PRIVILEGES" or a comma-separated privs: list
      # into individual privilege names, validating each against the
      # known set for *type*.
      def self.resolve_privs(type : String, privs : String) : Array(String)
        letters = PRIV_LETTERS[type]? || raise "unsupported type for postgresql_privs: #{type.inspect}"
        names = privs.split(',').map(&.strip.upcase).reject(&.empty?)

        if names.size == 1 && (names[0] == "ALL" || names[0] == "ALL PRIVILEGES")
          return all_privs(type)
        end

        names.each do |name|
          raise "unknown #{type} privilege: #{name.inspect}" unless letters.has_key?(name)
        end
        names
      end

      def self.letter_for(type : String, priv : String) : Char
        (PRIV_LETTERS[type]? || raise "unsupported type for postgresql_privs: #{type.inspect}")[priv]? ||
          raise "unknown #{type} privilege: #{priv.inspect}"
      end

      record Grant, letter : Char, grant_option : Bool

      # Parses a `relacl`/`nspacl`/`datacl` `::text` value into
      # {grantee_name => {letter => grant_option}}. `PUBLIC`'s entry (an
      # empty grantee before the `=`) is keyed under the literal string
      # "PUBLIC" for callers' convenience, not "". `nil`/empty input (a
      # SQL NULL ACL column, meaning no explicit grants exist yet beyond
      # the object's implicit owner/PUBLIC defaults) parses to an empty
      # hash - every privilege then reads as "not granted", which is the
      # correct default for GRANT idempotency purposes here even though
      # it doesn't reflect PostgreSQL's own implicit-default grants
      # (documented simplification, matching how postgresql_user.cr
      # already doesn't compare against inherited role membership either).
      def self.parse(acl_text : String?) : Hash(String, Hash(Char, Bool))
        result = Hash(String, Hash(Char, Bool)).new
        return result if acl_text.nil? || acl_text.empty?

        inner = acl_text.strip
        inner = inner[1..-2] if inner.starts_with?('{') && inner.ends_with?('}')
        return result if inner.empty?

        split_entries(inner).each do |entry|
          grantee_raw, rest = entry.split('=', 2)
          privs_part = rest.split('/', 2)[0]
          grantee = grantee_raw.empty? ? "PUBLIC" : grantee_raw

          privs = result[grantee] ||= Hash(Char, Bool).new
          i = 0
          while i < privs_part.size
            letter = privs_part[i]
            grant_option = i + 1 < privs_part.size && privs_part[i + 1] == '*'
            privs[letter] = grant_option
            i += grant_option ? 2 : 1
          end
        end

        result
      end

      # Splits the comma-separated aclitem list. Every field inside a
      # single aclitem (`grantee=privs/grantor`) that could itself
      # contain a comma - a double-quoted role name - is a real
      # PostgreSQL possibility (any identifier can be double-quoted with
      # arbitrary characters), so a plain `String#split(',')` isn't safe;
      # track quoting state instead.
      private def self.split_entries(inner : String) : Array(String)
        entries = [] of String
        current = String::Builder.new
        in_quotes = false

        inner.each_char do |char|
          if char == '"'
            in_quotes = !in_quotes
            current << char
          elsif char == ',' && !in_quotes
            entries << current.to_s
            current = String::Builder.new
          else
            current << char
          end
        end
        last = current.to_s
        entries << last unless last.empty?
        entries
      end

      def self.has_privilege?(parsed : Hash(String, Hash(Char, Bool)), grantee : String, letter : Char) : Bool
        parsed[grantee]?.try(&.has_key?(letter)) || false
      end

      def self.has_grant_option?(parsed : Hash(String, Hash(Char, Bool)), grantee : String, letter : Char) : Bool
        parsed[grantee]?.try { |privs| privs[letter]? } || false
      end
    end
  end
end
