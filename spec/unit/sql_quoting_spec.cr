require "../spec_helper"
require "../../src/krikri/plugin_helpers/sql_quoting"

# The one shared SQL-quoting primitive for the DB-family plugins (was
# five per-plugin `quote_ident` copies + three `quote_str` copies,
# all byte-identical within a dialect - the same drift trap this
# project has hit with shell_single_quote before).
describe Krikri::PluginHelpers::SqlQuoting do
  describe ".pg_quote_ident" do
    it "wraps in double quotes and doubles embedded ones" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_ident("mydb").should eq("\"mydb\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_ident("weird\"db").should eq("\"weird\"\"db\"")
    end

    it "is round-trip safe: every string yields a single identifier" do
      nasty = "a\"; DROP TABLE users; --"
      # A correctly quoted identifier can only be mis-parsed if an
      # embedded quote escapes it - doubling makes that impossible.
      quoted = Krikri::PluginHelpers::SqlQuoting.pg_quote_ident(nasty)
      quoted.starts_with?('"').should be_true
      quoted.ends_with?('"').should be_true
      # outer pair + every embedded quote doubled
      quoted.count('"').should eq(2 + nasty.count('"') * 2)
    end
  end

  describe ".mysql_quote_ident" do
    it "wraps in backticks and doubles embedded ones" do
      Krikri::PluginHelpers::SqlQuoting.mysql_quote_ident("mydb").should eq("`mydb`")
      Krikri::PluginHelpers::SqlQuoting.mysql_quote_ident("weird`db").should eq("`weird``db`")
    end
  end

  describe ".quote_str" do
    it "wraps in single quotes and doubles embedded ones (both dialects)" do
      Krikri::PluginHelpers::SqlQuoting.quote_str("plain").should eq("'plain'")
      Krikri::PluginHelpers::SqlQuoting.quote_str("it's").should eq("'it''s'")
      Krikri::PluginHelpers::SqlQuoting.quote_str("'; DROP TABLE users; --").should eq("'''; DROP TABLE users; --'")
    end
  end

  # Every expected string below was produced by the REAL implementation:
  # community.postgresql's pg_quote_identifier (which delegates to
  # Ansible's _identifier_parse), imported directly from
  # ~/.ansible/collections/.../module_utils/database.py under python3 -
  # not hand-derived. This is what pins parity with real Ansible.
  describe ".pg_quote_identifier" do
    it "quotes simple identifiers, preserving case" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("public", "table").should eq("\"public\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("mydb", "database").should eq("\"mydb\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("A_b1", "role").should eq("\"A_b1\"")
    end

    it "accepts identifiers real Ansible accepts that an allow-list would reject" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("peering-manager", "role").should eq("\"peering-manager\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("my schema", "schema").should eq("\"my schema\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a b", "table").should eq("\"a b\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("café", "table").should eq("\"café\"")
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a,b", "table").should eq("\"a,b\"")
    end

    it "doubles embedded double quotes" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a"b), "table").should eq(%q("a""b"))
    end

    it "leaves quotes, semicolons, comment markers and backslashes safely inside the quoting" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a'b), "table").should eq(%q("a'b"))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a;b), "table").should eq(%q("a;b"))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a--b), "table").should eq(%q("a--b"))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a\b), "table").should eq(%q("a\b"))
    end

    it "splits unquoted dotted paths per fragment (real Ansible's own handling)" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a.b", "table").should eq(%q("a"."b"))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a.b.c", "table").should eq(%q("a"."b"."c"))
    end

    it "quotes a leading/trailing dot as part of one identifier (real behavior)" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a.", "table").should eq(%q("a."))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(".a", "table").should eq(%q(".a"))
    end

    it "passes already-quoted input through unchanged (real behavior)" do
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q("already quoted"), "table").should eq(%q("already quoted"))
      Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q("a"."b"), "table").should eq(%q("a"."b"))
    end

    it "raises real Ansible's own errors on over-deep dotted paths" do
      expect_raises(Krikri::PluginHelpers::SqlQuoting::SQLParseError, "PostgreSQL does not support table with more than 3 dots") do
        Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a.b.c.d", "table")
      end
      expect_raises(Krikri::PluginHelpers::SqlQuoting::SQLParseError, "PostgreSQL does not support database with more than 1 dots") do
        Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("a.b", "database")
      end
    end

    it "raises real Ansible's own error on an empty identifier" do
      expect_raises(Krikri::PluginHelpers::SqlQuoting::SQLParseError, "Identifier name unspecified or unquoted trailing dot") do
        Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("", "table")
      end
    end

    # Injection property: for arbitrary text with no dot and no leading
    # quote, the output is exactly one double-quoted fragment whose
    # unescaping recovers the original - the identifier can never break
    # out of the quoting, no matter what characters it carries.
    it "is injection-safe for arbitrary identifier text" do
      nasty = [
        %q(a"; DROP TABLE users; --),
        %q(it's),
        %q(a;b),
        %q(a--b),
        %q(a b),
        %q(café),
        %q(a\b),
        %q(a,b),
        %q{a)b},
        %q{a[b]},
      ]
      nasty.each do |value|
        quoted = Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(value, "table")
        quoted.starts_with?('"').should be_true, "unquoted output for #{value.inspect}: #{quoted.inspect}"
        quoted.ends_with?('"').should be_true, "unterminated output for #{value.inspect}: #{quoted.inspect}"
        quoted.count('"').should eq(2 + value.count('"') * 2),
          "unbalanced quoting for #{value.inspect}: #{quoted.inspect}"
        # strip the outer pair, undo the doubling -> the original text
        quoted[1..-2].gsub("\"\"", "\"").should eq(value)
      end
    end

    it "quotes every fragment of a dotted path injection-safely" do
      quoted = Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q(a";DROP.b --), "table")
      quoted.should eq(%q("a"";DROP"."b --"))
      left, right = quoted.split(".")
      left[1..-2].gsub("\"\"", "\"").should eq(%q(a";DROP))
      right[1..-2].gsub("\"\"", "\"").should eq(%q(b --))
    end

    it "rejects malformed pre-quoted input with real Ansible's own message" do
      expect_raises(Krikri::PluginHelpers::SqlQuoting::SQLParseError, "User escaped identifiers must escape extra quotes") do
        Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier(%q("a"b), "table")
      end
    end

    it "raises for an unknown identifier type (real behavior)" do
      expect_raises(Krikri::PluginHelpers::SqlQuoting::SQLParseError, "Unknown identifier type view") do
        Krikri::PluginHelpers::SqlQuoting.pg_quote_identifier("v", "view")
      end
    end
  end
end
