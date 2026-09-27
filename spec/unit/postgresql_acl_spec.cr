require "../spec_helper"
require "../../src/krikri/plugin_helpers/postgresql_acl"

describe Krikri::PluginHelpers::PostgresqlAcl do
  describe ".parse" do
    it "returns an empty hash for a nil ACL (no explicit grants)" do
      Krikri::PluginHelpers::PostgresqlAcl.parse(nil).should eq({} of String => Hash(Char, Bool))
    end

    it "parses a real relacl value, grant-option and plain privileges alike" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{postgres=arwdDxtm/postgres,bob=rw/postgres,alice=r*/postgres}")

      parsed["postgres"].keys.sort!.should eq(['D', 'a', 'd', 'm', 'r', 't', 'w', 'x'])
      parsed["bob"].should eq({'r' => false, 'w' => false})
      parsed["alice"].should eq({'r' => true})
    end

    it "keys an empty grantee (PUBLIC's own aclitem entry) under the literal string PUBLIC" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{=Tc/postgres,postgres=CTc/postgres}")
      parsed["PUBLIC"].should eq({'T' => false, 'c' => false})
    end

    it "distinguishes grant-option per individual privilege on the same entry" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")
      parsed["bob"].should eq({'r' => true, 'w' => false})
    end

    # PostgreSQL array-text: an aclitem whose grantee needs quoting is
    # wrapped in array-level quotes with every embedded quote
    # backslash-escaped. Keyed under the UNQUOTED role name - the same
    # name the GRANT was issued for - or idempotency re-grants forever.
    it "unescapes and unquotes array-escaped quoted grantees" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner,"\"peering-manager\"=U/pg_database_owner"}]
      )
      parsed["pg_database_owner"].should eq({'U' => false, 'C' => false})
      parsed["PUBLIC"].should eq({'U' => false})
      parsed["peering-manager"].should eq({'U' => false})
    end

    it "round-trips a grantee whose own name contains a double quote" do
      # role ro"le-x -> grantee renders as "ro""le-x", array-escaped as
      # "ro""le-x" wrapped: "\"ro\"\"le-x\"=U/postgres"
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{"\"ro\"\"le-x\"=U/postgres"}]
      )
      parsed[%q(ro"le-x)].should eq({'U' => false})
    end

    it "keys a quoted grantee containing an equals sign or comma under its full name" do
      parsed = Krikri::PluginHelpers::PostgresqlAcl.parse(
        %q[{"\"a=b,c\"=U/postgres"}]
      )
      parsed["a=b,c"].should eq({'U' => false})
    end
  end

  describe ".has_privilege?/.has_grant_option?" do
    parsed = Krikri::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")

    it "reports a granted privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'r').should be_true
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'w').should be_true
    end

    it "reports a privilege the grantee doesn't have" do
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'd').should be_false
      Krikri::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "nobody", 'r').should be_false
    end

    it "reports grant option correctly per privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'r').should be_true
      Krikri::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'w').should be_false
    end
  end

  describe ".resolve_privs" do
    it "expands ALL to every table privilege" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL").should eq(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "expands ALL PRIVILEGES the same way" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL PRIVILEGES").should eq(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "parses a comma-separated explicit list, uppercasing and trimming" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", " select, update ").should eq(%w[SELECT UPDATE])
    end

    it "raises on an unknown privilege for the given type" do
      expect_raises(Exception, /unknown table privilege/) do
        Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("table", "CONNECT")
      end
    end

    it "resolves database privileges separately from table privileges" do
      Krikri::PluginHelpers::PostgresqlAcl.resolve_privs("database", "ALL").should eq(%w[CREATE CONNECT TEMPORARY])
    end
  end

  describe ".letter_for" do
    it "maps privilege names to their ACL letter per type" do
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("table", "SELECT").should eq('r')
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("database", "CONNECT").should eq('c')
      Krikri::PluginHelpers::PostgresqlAcl.letter_for("schema", "USAGE").should eq('U')
    end
  end
end
