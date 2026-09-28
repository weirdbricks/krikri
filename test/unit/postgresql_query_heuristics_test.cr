require "../minitest_helper"
require "json"
require "../../src/krikri/plugin_helpers/postgresql_query_heuristics"

# Unit-tests the changed-determination and named-arg expansion against
# real community.postgresql.postgresql_query's own behavior (read from
# its source) - the plugin's execution paths need a live PostgreSQL
# server, these don't.
describe Krikri::PluginHelpers::PostgresqlQueryHeuristics do
  include RaisesAssertion
  describe ".leading_keyword" do
    include RaisesAssertion
    it "reads through leading comments and whitespace" do
      sql = "-- check server\n\nSELECT version();"
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).must_equal("SELECT")
    end

    it "reads through block comments" do
      sql = "/* note */ SHOW server_version;"
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword(sql).must_equal("SHOW")
    end

    it "is empty for a comment-only statement" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.leading_keyword("-- nothing").must_equal("")
    end
  end

  describe ".changed?" do
    include RaisesAssertion
    it "never reports changed for SELECT/SHOW" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("SELECT", 3).must_equal(false)
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("SHOW", 1).must_equal(false)
    end

    it "reports changed for row-affecting DML only when rows changed" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("INSERT", 1).must_equal(true)
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("UPDATE", 0).must_equal(false)
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("DELETE", 2).must_equal(true)
    end

    it "always reports changed for other statements (real module's else branch)" do
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("CREATE", 0).must_equal(true)
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("TRUNCATE", 0).must_equal(true)
      Krikri::PluginHelpers::PostgresqlQueryHeuristics.changed?("ALTER", 0).must_equal(true)
    end
  end

  describe ".expand_named_args" do
    include RaisesAssertion
    it "rewrites %(name)s to $N in first-appearance order" do
      sql = "SELECT * FROM t WHERE id = %(id_val)s AND story = %(story_val)s"
      expanded, args = Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
        sql, {"id_val" => JSON.parse("1"), "story_val" => JSON.parse("\"test\"")}
      )
      expanded.must_equal("SELECT * FROM t WHERE id = $1 AND story = $2")
      args.map(&.to_s).must_equal(["1", "test"])
    end

    it "reuses one position for a repeated name" do
      expanded, args = Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
        "SELECT %(x)s, %(x)s", {"x" => JSON.parse("\"a\"")}
      )
      expanded.must_equal("SELECT $1, $1")
      args.size.must_equal(1)
    end

    it "raises when a name is missing from the dict" do
      assert_raises_message(Exception, /named argument/) do
        Krikri::PluginHelpers::PostgresqlQueryHeuristics.expand_named_args(
          "SELECT %(nope)s", {"x" => JSON.parse("1")}
        )
      end
    end
  end
end
