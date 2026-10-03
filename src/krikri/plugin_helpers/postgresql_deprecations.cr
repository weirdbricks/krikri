require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # The DEPRECATION WARNINGS real (ansible-core 2.19.11 +
    # community.postgresql 4.2.0) emits when a postgresql_* task
    # spells one of the shared connection params with its deprecated
    # alias. The aliases are still accepted - PostgresqlConnection's
    # #resolve_login_params resolves them to the same values - but
    # real's AnsibleModule prints a [DEPRECATION WARNING] line for each
    # one AND appends a `deprecations` entry to the module result, which
    # is where a task registering the result sees it.
    #
    # Live-verified against real for every alias on all four modules:
    # - console (stderr, once per distinct text per run, after the
    #   one-time "Deprecation warnings can be disabled" hint):
    #   Alias 'host' is deprecated. See the module docs for more
    #   information. This feature will be removed from collection
    #   'community.postgresql' version 5.0.0.
    # - registered result, appended as the LAST key (after `failed`,
    #   on both success and failure results):
    #   {"msg": "Alias 'host' is deprecated. See the module docs for
    #    more information", "collection_name": "community.postgresql",
    #    "version": "5.0.0", "deprecator": {"resolved_name":
    #    "community.postgresql", "type": null}}
    # Order is the shared argument_spec's declaration order (login_user,
    # login_host, login_unix_socket, login_port, then login_db), NOT the
    # order the aliases appear in the task - verified with a postgresql_privs
    # task setting login:, unix_socket: and db: together.
    #
    # The version string is real's own `deprecated_aliases` metadata for
    # community.postgresql 4.2.0, hard-coded: it names the collection
    # RELEASE that will drop the alias (5.0.0), not the installed one,
    # so it is a constant of the collection's deprecation policy and not
    # something a krikri install could discover about itself.
    module PostgresqlDeprecations
      COLLECTION      = "community.postgresql"
      REMOVAL_VERSION = "5.0.0"

      # alias name => the canonical param it stands for, in the shared
      # spec's declaration order.
      ALIASES = {
        "login"       => "login_user",
        "host"        => "login_host",
        "unix_socket" => "login_unix_socket",
        "port"        => "login_port",
        "db"          => "login_db",
      }

      # The warning real's AnsibleModule emits (via self.warn(), which
      # both prints `[WARNING]: <text>` on stderr and appends to the
      # result's `warnings` list) when a community.postgresql module is
      # asked to connect without naming a database, so psycopg2 falls
      # back to the connection default.
      #
      # Live-verified against real ansible-core 2.19.11 +
      # community.postgresql 4.2.0, per module:
      # - postgresql_query: warns, on success AND on failure (the
      #   fail_json "unable to connect to database: ..." result carries
      #   it too, last key after `exception`). Its `db:` alias counts
      #   as a database name, so it does NOT warn then.
      # - postgresql_db / postgresql_user: NEVER warn - their own
      #   `db`/`name` param is the database they manage and their login
      #   database is a documented default; real's result has no
      #   `warnings` key at all when login_db is absent.
      # - postgresql_privs: real REQUIRES login_db ("missing required
      #   arguments: login_db"), so the warning can never fire there.
      DEFAULT_DB_WARNING = "Database name has not been passed, used default database to connect to."

      # Adds DEFAULT_DB_WARNING to `result.extra["warnings"]` when the
      # task named no database at all (neither `login_db` nor the `db`
      # alias). Call BEFORE PostgresqlDeprecations.finalize so the
      # registered result orders the two lists as real does:
      # ..., failed, warnings, deprecations.
      def self.add_default_db_warning(result : PluginResult, params : Hash(String, String)) : PluginResult
        return result if params.has_key?("login_db") || params.has_key?("db")

        existing = result.extra["warnings"]?.try(&.as_a?)
        texts = existing ? existing.map(&.as_s) : [] of String
        texts << DEFAULT_DB_WARNING unless texts.includes?(DEFAULT_DB_WARNING)
        result.extra["warnings"] = JSON::Any.new(texts.map { |text| JSON::Any.new(text) })
        result
      end

      # Adds the deprecations a task's params trigger to an otherwise
      # finished PluginResult. `db_alias:` is false for postgresql_db,
      # whose own `db` param (the database it manages, aliased `name`)
      # is NOT the shared spec's deprecated login_db alias - real emits
      # no deprecation for it.
      def self.finalize(result : PluginResult, params : Hash(String, String), db_alias : Bool = true) : PluginResult
        used = ALIASES.keys.select do |name|
          (db_alias || name != "db") && params.has_key?(name)
        end
        return result if used.empty?

        entries = used.map do |name|
          entry = Hash(String, JSON::Any).new
          entry["msg"] = JSON::Any.new("Alias '#{name}' is deprecated. See the module docs for more information")
          entry["collection_name"] = JSON::Any.new(COLLECTION)
          entry["version"] = JSON::Any.new(REMOVAL_VERSION)
          entry["deprecator"] = JSON::Any.new({
            "resolved_name" => JSON::Any.new(COLLECTION),
            "type"          => JSON::Any.new(nil),
          })
          JSON::Any.new(entry)
        end

        # `_ansible_core_deprecations` is the engine-internal marker
        # ResultDisplay turns into the [DEPRECATION WARNING] lines
        # (ansible.posix.mount's own core deprecation rides the same
        # channel); it is stripped before a registered result, and
        # `deprecations` itself is the real list a task registers.
        result.extra["deprecations"] = JSON::Any.new(entries)
        result.extra["_ansible_core_deprecations"] = JSON::Any.new(used.map do |name|
          JSON::Any.new("Alias '#{name}' is deprecated. See the module docs for more information. " \
                        "This feature will be removed from collection '#{COLLECTION}' version #{REMOVAL_VERSION}.")
        end)
        result
      end
    end
  end
end
