require "../minitest_helper"
require "../../src/krikri/plugin_helpers/postgresql_role_flags"

describe Krikri::PluginHelpers::PostgresqlRoleFlags do
  include RaisesAssertion
  describe ".parse" do
    include RaisesAssertion
    it "parses positive flags as true" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("LOGIN,CREATEDB")
        .must_equal({"LOGIN" => true, "CREATEDB" => true})
    end

    it "parses NO-prefixed flags as false" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("NOSUPERUSER,NOLOGIN")
        .must_equal({"SUPERUSER" => false, "LOGIN" => false})
    end

    it "is case-insensitive" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("login,nocreatedb")
        .must_equal({"LOGIN" => true, "CREATEDB" => false})
    end

    it "raises on an unknown flag" do
      assert_raises_message(Exception, /unknown role attribute flag/) do
        Krikri::PluginHelpers::PostgresqlRoleFlags.parse("NOTAREALFLAG")
      end
    end
  end

  describe ".to_sql" do
    include RaisesAssertion
    it "renders a flags hash into a CREATE/ALTER ROLE clause" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.to_sql({"LOGIN" => true, "SUPERUSER" => false})
        .must_equal("LOGIN NOSUPERUSER")
    end
  end

  describe ".column_for" do
    include RaisesAssertion
    it "maps every known flag to a real pg_roles column" do
      Krikri::PluginHelpers::PostgresqlRoleFlags::FLAGS.each do |flag|
        expect(str_starts_with?(Krikri::PluginHelpers::PostgresqlRoleFlags.column_for(flag), "rol")).must_equal(true)
      end
    end

    it "raises for an unknown flag" do
      assert_raises_message(Exception, /unknown role attribute flag/) do
        Krikri::PluginHelpers::PostgresqlRoleFlags.column_for("NOTAREALFLAG")
      end
    end
  end
end
