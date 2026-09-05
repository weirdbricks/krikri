require "json"

module Krikri
  module PluginHelpers
    # Single shared SQL quoting implementation for the DB-family plugins
    # (mysql_*, postgresql_*). These used to exist as per-plugin private
    # copies - five `quote_ident` and three `quote_str` definitions, all
    # byte-identical within a dialect - which for SECURITY-RELEVANT
    # quoting primitives is several chances to drift (one copy gaining
    # an escape the others lack is exactly the bug class this project
    # has hit with shell_single_quote and rerender_if_templated before).
    #
    # These are standard SQL/quoting rules, not Ansible semantics:
    # - identifier: double quotes for PostgreSQL, backticks for MySQL,
    #   with the delimiter doubled inside.
    # - string literal: single quotes with the quote doubled (both
    #   dialects agree).
    # They are NOT full injection defenses (they assume the caller
    # passes a lone identifier/literal, not arbitrary SQL fragments) -
    # same trust boundary real Ansible's own DB modules work within.
    module SqlQuoting
      # PostgreSQL double-quoted identifier: "name" with embedded "
      # doubled (standard_sql identifier quoting, which PostgreSQL also
      # honors with quoted_identifiers_aware downcasing only for
      # unquoted - the quotes here preserve case, matching what the
      # per-plugin copies did).
      def self.pg_quote_ident(s : String) : String
        "\"" + s.gsub("\"", "\"\"") + "\""
      end

      # MySQL backtick-quoted identifier: `name` with embedded `
      # doubled.
      def self.mysql_quote_ident(s : String) : String
        "`" + s.gsub("`", "``") + "`"
      end

      # Single-quoted SQL string literal - identical form in both
      # dialects: 'value' with embedded ' doubled.
      def self.quote_str(s : String) : String
        "'" + s.gsub("'", "''") + "'"
      end
    end
  end
end
