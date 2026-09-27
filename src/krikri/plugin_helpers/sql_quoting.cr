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
      # Faithful port of community.postgresql's pg_quote_identifier
      # (module_utils/database.py), which itself wraps Ansible's shared
      # _identifier_parse. It takes the *raw* user-supplied identifier text
      # and returns SQL text:
      # - an unquoted identifier (or dotted path) has every fragment wrapped
      #   in double quotes, embedded quotes doubled;
      # - a dotted unquoted path is split at the dots and each fragment
      #   quoted separately ("a.b" -> '"a"."b"');
      # - already-quoted input passes through unchanged (the caller is
      #   trusted to have escaped it, exactly as the Python does);
      # - a leading/trailing/unpaired quote, an empty identifier and an
      #   over-deep dotted path all raise SQLParseError with the Python
      #   originals' exact messages.
      # The id_type controls how many dot levels the identifier may carry
      # (a column can be db.schema.table.column, a role only ever one
      # name), mirroring _PG_IDENTIFIER_TO_DOT_LEVEL.
      # Every fragment comes back double-quoted, so arbitrary identifier
      # text (quotes, semicolons, dashes, spaces, unicode, backslashes)
      # cannot break out of the quoting - injection-safe by construction,
      # unlike a character allow-list.
      class SQLParseError < Exception
      end

      PG_IDENTIFIER_TO_DOT_LEVEL = {
        "database"    => 1,
        "schema"      => 2,
        "table"       => 3,
        "column"      => 4,
        "role"        => 1,
        "tablespace"  => 1,
        "sequence"    => 3,
        "publication" => 1,
      }

      def self.pg_quote_identifier(identifier : String, id_type : String) : String
        level = PG_IDENTIFIER_TO_DOT_LEVEL[id_type]?
        raise SQLParseError.new("Unknown identifier type #{id_type}") unless level

        fragments = parse_identifier_fragments(identifier, '"')
        if fragments.size > level
          raise SQLParseError.new("PostgreSQL does not support #{id_type} with more than #{level} dots")
        end

        fragments.join(".")
      end

      private UNCLOSED_QUOTE = "unclosed quote"

      # Direct port of Python's _identifier_parse; see the pg_quote_
      # identifier doc comment for the behavior contract.
      private def self.parse_identifier_fragments(identifier : String, quote_char : Char) : Array(String)
        raise SQLParseError.new("Identifier name unspecified or unquoted trailing dot") if identifier.empty?

        already_quoted = identifier[0] == quote_char
        further = [] of String

        if already_quoted
          end_quote = begin
            find_end_quote(identifier[1..], quote_char) + 1
          rescue
            nil
          end

          if eq = end_quote
            if eq < identifier.size - 1
              if identifier[eq + 1]? == '.'
                dot = eq + 1
                first_identifier = identifier[0...dot]
                next_identifier = slice_from(identifier, dot + 1)
                further = parse_identifier_fragments(next_identifier, quote_char)
                further.unshift(first_identifier)
              else
                raise SQLParseError.new("User escaped identifiers must escape extra quotes")
              end
            else
              further = [identifier]
            end
          else
            already_quoted = false
          end
        end

        unless already_quoted
          dot = identifier.index('.')
          if dot.nil? || dot == 0 || dot >= identifier.size - 1
            further = [wrap_identifier(identifier, quote_char)]
          else
            first_identifier = wrap_identifier(identifier[0...dot], quote_char)
            further = parse_identifier_fragments(slice_from(identifier, dot + 1), quote_char)
            further.unshift(first_identifier)
          end
        end

        further
      end

      # Python's identifier[quote+1] IndexError -> "no char here" is this
      # nil check; Python's identifier[quote+2:] empty-slice-at-the-end
      # falls through to the next loop iteration's UnclosedQuoteError, which
      # the same nil check reaches on the following round.
      private def self.find_end_quote(identifier : String, quote_char : Char) : Int32
        accumulate = 0
        rest = identifier
        loop do
          quote = rest.index(quote_char)
          raise SQLParseError.new(UNCLOSED_QUOTE) if quote.nil?

          accumulate += quote
          next_char = rest[(quote + 1)]?
          return accumulate if next_char.nil?

          if next_char == quote_char
            rest = slice_from(rest, quote + 2)
            accumulate += 2
          else
            return accumulate
          end
        end
      end

      private def self.wrap_identifier(identifier : String, quote_char : Char) : String
        q = quote_char.to_s
        q + identifier.gsub(q, q * 2) + q
      end

      # Python s[i:] semantics: an i past the end yields "" rather than an
      # error (Crystal's s[i..] raises IndexError there instead).
      private def self.slice_from(s : String, i : Int) : String
        i <= s.size ? s[i..] : ""
      end

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
