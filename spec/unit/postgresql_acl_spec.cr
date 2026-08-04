require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/postgresql_acl"

describe CrystalPlay::PluginHelpers::PostgresqlAcl do
  describe ".parse" do
    it "returns an empty hash for a nil ACL (no explicit grants)" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.parse(nil).should eq({} of String => Hash(Char, Bool))
    end

    it "parses a real relacl value, grant-option and plain privileges alike" do
      parsed = CrystalPlay::PluginHelpers::PostgresqlAcl.parse("{postgres=arwdDxtm/postgres,bob=rw/postgres,alice=r*/postgres}")

      parsed["postgres"].keys.sort.should eq(['D', 'a', 'd', 'm', 'r', 't', 'w', 'x'])
      parsed["bob"].should eq({'r' => false, 'w' => false})
      parsed["alice"].should eq({'r' => true})
    end

    it "keys an empty grantee (PUBLIC's own aclitem entry) under the literal string PUBLIC" do
      parsed = CrystalPlay::PluginHelpers::PostgresqlAcl.parse("{=Tc/postgres,postgres=CTc/postgres}")
      parsed["PUBLIC"].should eq({'T' => false, 'c' => false})
    end

    it "distinguishes grant-option per individual privilege on the same entry" do
      parsed = CrystalPlay::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")
      parsed["bob"].should eq({'r' => true, 'w' => false})
    end
  end

  describe ".has_privilege?/.has_grant_option?" do
    parsed = CrystalPlay::PluginHelpers::PostgresqlAcl.parse("{bob=r*w/postgres}")

    it "reports a granted privilege" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'r').should be_true
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'w').should be_true
    end

    it "reports a privilege the grantee doesn't have" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "bob", 'd').should be_false
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_privilege?(parsed, "nobody", 'r').should be_false
    end

    it "reports grant option correctly per privilege" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'r').should be_true
      CrystalPlay::PluginHelpers::PostgresqlAcl.has_grant_option?(parsed, "bob", 'w').should be_false
    end
  end

  describe ".resolve_privs" do
    it "expands ALL to every table privilege" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL").should eq(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "expands ALL PRIVILEGES the same way" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.resolve_privs("table", "ALL PRIVILEGES").should eq(
        %w[SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER]
      )
    end

    it "parses a comma-separated explicit list, uppercasing and trimming" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.resolve_privs("table", " select, update ").should eq(%w[SELECT UPDATE])
    end

    it "raises on an unknown privilege for the given type" do
      expect_raises(Exception, /unknown table privilege/) do
        CrystalPlay::PluginHelpers::PostgresqlAcl.resolve_privs("table", "CONNECT")
      end
    end

    it "resolves database privileges separately from table privileges" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.resolve_privs("database", "ALL").should eq(%w[CREATE CONNECT TEMPORARY])
    end
  end

  describe ".letter_for" do
    it "maps privilege names to their ACL letter per type" do
      CrystalPlay::PluginHelpers::PostgresqlAcl.letter_for("table", "SELECT").should eq('r')
      CrystalPlay::PluginHelpers::PostgresqlAcl.letter_for("database", "CONNECT").should eq('c')
      CrystalPlay::PluginHelpers::PostgresqlAcl.letter_for("schema", "USAGE").should eq('U')
    end
  end
end
