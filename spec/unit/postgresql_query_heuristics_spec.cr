require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/postgresql_query_heuristics"

# Unit-tests the changed-determination and named-arg expansion against
# real community.postgresql.postgresql_query's own behavior (read from
# its source) - the plugin's execution paths need a live PostgreSQL
# server, these don't.
describe Krikri::PluginHelpers::PostgresqlQueryHeuristics do
  describe ".leading_keyword" do
    it "reads through leading comments and whitespace" do
      sql = "-- check server\n\nSELECT version();"
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).should eq("SELECT")
    end

    it "reads through block comments" do
      sql = "/* note */ SHOW server_version;"
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).should eq("SHOW")
    end

    it "is empty for a comment-only statement" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword("-- nothing").should eq("")
    end
  end

  describe ".changed?" do
    it "never reports changed for SELECT/SHOW" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("SELECT", 3).should be_false
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("SHOW", 1).should be_false
    end

    it "reports changed for row-affecting DML only when rows changed" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("INSERT", 1).should be_true
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("UPDATE", 0).should be_false
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("DELETE", 2).should be_true
    end

    it "always reports changed for other statements (real module's else branch)" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("CREATE", 0).should be_true
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("TRUNCATE", 0).should be_true
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("ALTER", 0).should be_true
    end
  end

  describe ".expand_named_args" do
    it "rewrites %(name)s to $N in first-appearance order" do
      sql = "SELECT * FROM t WHERE id = %(id_val)s AND story = %(story_val)s"
      expanded, args = Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
        sql, {"id_val" => JSON.parse("1"), "story_val" => JSON.parse("\"test\"")}
      )
      expanded.should eq("SELECT * FROM t WHERE id = $1 AND story = $2")
      args.map(&.to_s).should eq(["1", "test"])
    end

    it "reuses one position for a repeated name" do
      expanded, args = Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
        "SELECT %(x)s, %(x)s", {"x" => JSON.parse("\"a\"")}
      )
      expanded.should eq("SELECT $1, $1")
      args.size.should eq(1)
    end

    it "raises when a name is missing from the dict" do
      expect_raises(Exception, /named argument/) do
        Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
          "SELECT %(nope)s", {"x" => JSON.parse("1")}
        )
      end
    end
  end
end
