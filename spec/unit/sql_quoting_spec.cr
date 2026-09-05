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
end
