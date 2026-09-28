require "../minitest_helper"
require "../../src/krikri/plugin_helpers/postgresql_acl"

describe Krikri::PluginHelpers::PostgresqlAcl do
  describe ".parse" do
    it "returns an empty hash for a nil ACL (no explicit grants)" do
      Krikri::PluginHelpers::PostgresqlAcl.parse(nil).must_equal({} of String => Hash(Char, Bool))
    end

    it "parses a real relacl value, grant-option and plain privileges alike" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{postgres=arwdDxtm/postgres,bob=rw/postgres,alice=r*/postgres}")

      parsed["postgres"].keys.sort!.must_equal(['D', 'a', 'd', 'm', 'r', 't', 'w', 'x'])
      parsed["bob"].must_equal({'r' => false, 'w' => false})
      parsed["alice"].must_equal({'r' => true})
    end

    it "keys an empty grantee (PUBLIC's own aclitem entry) under the literal string PUBLIC" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{=Tc/postgres,postgres=CTc/postgres}")
      parsed["PUBLIC"].must_equal({'T' => false, 'c' => false})
    end

    it "distinguishes grant-option per individual privilege on the same entry" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")
      parsed["bob"].must_equal({'r' => true, 'w' => false})
    end

    # PostgreSQL array-text: an aclitem whose grantee needs quoting is
    # wrapped in array-level quotes with every embedded quote
    # backslash-escaped. Keyed under the UNQUOTED role name - the same
    # name the GRANT was issued for - or idempotency re-grants forever.
    it "unescapes and unquotes array-escaped quoted grantees" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner,"\"peering-manager\"=U/pg_database_owner"}]
      )
      parsed["pg_database_owner"].must_equal({'U' => false, 'C' => false})
      parsed["PUBLIC"].must_equal({'U' => false})
      parsed["peering-manager"].must_equal({'U' => false})
    end

    it "round-trips a grantee whose own name contains a double quote" do
      # role ro"le-x -> grantee renders as "ro""le-x", array-escaped as
      # "ro""le-x" wrapped: "\"ro\"\"le-x\"=U/postgres"
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{"\"ro\"\"le-x\"=U/postgres"}]
      )
      parsed[%q(ro"le-x)].must_equal({'U' => false})
    end

    it "keys a quoted grantee containing an equals sign or comma under its full name" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{"\"a=b,c\"=U/postgres"}]
      )
      parsed["a=b,c"].must_equal({'U' => false})
    end
  end

  describe ".has_privilege?/.has_grant_option?" do
    private def parsed
      Krikri::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")
    end

    it "reports a granted privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'r').must_equal(true)
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'w').must_equal(true)
    end

    it "reports a privilege the grantee doesn't have" do
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'd').must_equal(false)
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "nobody", 'r').must_equal(false)
    end

    it "reports grant option correctly per privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'r').must_equal(true)
      Krikri::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'w').must_equal(false)
    end
  end

  describe ".resolve_privs" do
    it "expands ALL to every table privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL").must_equal(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "expands ALL PRIVILEGES the same way" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL PRIVILEGES").must_equal(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "parses a comma-separated explicit list, uppercasing and trimming" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", " select, update ").must_equal(%w[SELECT UPDATE])
    end

    it "raises on an unknown privilege for the given type" do
      assert_raises_message(Exception, /unknown table privilege/) do
        Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "CONNECT")
      end
    end

    it "resolves database privileges separately from table privileges" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("database", "ALL").must_equal(%w[CREATE CONNECT TEMPORARY])
    end
  end

  describe ".letter_for" do
    it "maps privilege names to their ACL letter per type" do
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("table", "SELECT").must_equal('r')
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("database", "CONNECT").must_equal('c')
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("schema", "USAGE").must_equal('U')
    end
  end
end
