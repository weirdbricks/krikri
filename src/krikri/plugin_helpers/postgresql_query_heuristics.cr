module Krikri
  module PluginHelpers
    # PostgresqlQueryHeuristics - pure logic for postgresql_query (see
    # plugins/postgresql_query.cr): the changed-determination the real
    # module performs on psycopg's statusmessage (it cannot see row
    # counts for SELECT either - anything whose command tag is not
    # SELECT/SHOW counts as a change), and psycopg %(name)s named-arg
    # expansion down to positional binds (crystal-pg has no named-arg
    # binding).
    module PostgresqlQueryHeuristics
      # First significant SQL word, skipping line comments and block
      # comments - the same leading-keyword view the real module's
      # statusmessage check is driven by.
      def self.leading_keyword(sql : String) : String
        scanner = sql
        loop do
          scanner = scanner.lstrip
          if scanner.starts_with?("--")
            scanner = scanner.split('\n', 2)[1]? || ""
            next
          end
          if scanner.starts_with?("/*")
            _, _, rest = scanner.partition("*/")
            scanner = rest
            next
          end
          break
        end
        scanner.match(/\A[a-zA-Z_]+/).try(&.[0]) || ""
      end

      # The real module's rule, applied to the synthesized command tag:
      # SELECT/SHOW never report changed; UPDATE/INSERT/DELETE report
      # changed only when the affected-row count is non-zero (its
      # "len(s) == 2/3" checks); anything else (CREATE, DROP, ALTER,
      # TRUNCATE, SET, ...) always reports changed.
      def self.changed?(keyword : String, rows_affected : Int64) : Bool
        case keyword.upcase
        when "SELECT", "SHOW", "EXPLAIN"
          false
        when "UPDATE", "INSERT", "DELETE"
          rows_affected != 0
        else
          true
        end
      end

      # Rewrites psycopg-style %(name)s placeholders to $N binds and
      # returns the values in that order. Names appearing repeatedly
      # reuse their position. Raises on a name missing from the dict -
      # real psycopg raises "KeyError" equivalently.
      def self.expand_named_args(sql : String, named : Hash(String, JSON::Any)) : {String, Array(JSON::Any)}
        args = [] of JSON::Any
        mapping = Hash(String, Int32).new

        expanded = sql.gsub(/%\(([^)]+)\)s/) do
          name = $1
          raise "named argument '#{name}' not in named_args" unless named.has_key?(name)
          index = mapping[name]?
          unless index
            args << named[name]
            index = args.size
            mapping[name] = index
          end
          "$#{index}"
        end

        {expanded, args}
      end

      # JSON::Any bind value down to crystal-pg's accepted set - JSON
      # numbers are always Float64-or-Int64 from parse; keep everything
      # else as its rendered string (matching the module's own string
      # passthrough for arrays etc.).
      def self.bind_value(value : JSON::Any)
        case value.raw
        when Nil, Bool, Int64, Float64, String then value.raw
        else                                        value.to_s
        end
      end
    end
  end
end
