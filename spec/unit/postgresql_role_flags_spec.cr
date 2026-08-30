require "../spec_helper"
require "../../src/krikri/plugin_helpers/postgresql_role_flags"

describe Krikri::PluginHelpers::PostgresqlRoleFlags do
  describe ".parse" do
    it "parses positive flags as true" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("LOGIN,CREATEDB")
        .should eq({"LOGIN" => true, "CREATEDB" => true})
    end

    it "parses NO-prefixed flags as false" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("NOSUPERUSER,NOLOGIN")
        .should eq({"SUPERUSER" => false, "LOGIN" => false})
    end

    it "is case-insensitive" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.parse("login,nocreatedb")
        .should eq({"LOGIN" => true, "CREATEDB" => false})
    end

    it "raises on an unknown flag" do
      expect_raises(Exception, /unknown role attribute flag/) do
        Krikri::PluginHelpers::PostgresqlRoleFlags.parse("NOTAREALFLAG")
      end
    end
  end

  describe ".to_sql" do
    it "renders a flags hash into a CREATE/ALTER ROLE clause" do
      Krikri::PluginHelpers::PostgresqlRoleFlags.to_sql({"LOGIN" => true, "SUPERUSER" => false})
        .should eq("LOGIN NOSUPERUSER")
    end
  end

  describe ".column_for" do
    it "maps every known flag to a real pg_roles column" do
      Krikri::PluginHelpers::PostgresqlRoleFlags::FLAGS.each do |flag|
        Krikri::PluginHelpers::PostgresqlRoleFlags.column_for(flag).should start_with("rol")
      end
    end

    it "raises for an unknown flag" do
      expect_raises(Exception, /unknown role attribute flag/) do
        Krikri::PluginHelpers::PostgresqlRoleFlags.column_for("NOTAREALFLAG")
      end
    end
  end
end
