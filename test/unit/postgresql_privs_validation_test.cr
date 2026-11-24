require "../minitest_helper"

# postgresql_privs argument validation must reproduce Ansible's own
# pre-connection order and wording: schema/type compatibility first, then
# objs, then privs (community.postgresql's main(), live-verified against
# ansible-core 2.21.6 + community.postgresql 4.2.0). The reported case
# (#1750) had `type: database` with a `schema:` and no `privs:`, where
# Ansible fails on the schema while this plugin used to fail on privs.
#
# No PostgreSQL server is needed or wanted here: every one of these fails
# during argument validation, before any connection attempt (the login port
# points at nothing, so a connection attempt would fail differently).
private def privs_validation_msg(params : Hash(String, String)) : String
  result = PluginSpecHelper.run("postgresql_privs", {
    "login_host" => "127.0.0.1",
    "login_port" => "13399",
  }.merge(params))

  result["failed"].as_bool.must_equal(true)
  result["changed"].as_bool.must_equal(false)
  result["msg"].as_s
end

describe "postgresql_privs argument validation" do
  it "rejects schema for a type without one, before complaining about privs" do
    privs_validation_msg({
      "login_db" => "butfki",
      "objs"     => "kpgdb",
      "roles"    => "kpguser",
      "schema"   => "zlolmi",
      "type"     => "database",
    }).must_equal(%(Argument "schema" is not allowed for type "database".))
  end

  it "requires privs with Ansible's own wording for schema-bearing types" do
    privs_validation_msg({
      "login_db" => "postgres",
      "objs"     => "sometable",
      "roles"    => "kpguser",
      "type"     => "table",
    }).must_equal(%(Argument "privs" is required for type "table".))
  end

  it "rejects privs for type group with Ansible's own wording" do
    privs_validation_msg({
      "login_db" => "postgres",
      "objs"     => "somegroup",
      "roles"    => "kpguser",
      "privs"    => "SELECT",
      "type"     => "group",
    }).must_equal(%(Argument "privs" is not allowed for type "group".))
  end

  it "rejects ALL_IN_SCHEMA for a type it cannot expand, with Ansible's own wording" do
    privs_validation_msg({
      "login_db" => "postgres",
      "objs"     => "ALL_IN_SCHEMA",
      "roles"    => "kpguser",
      "privs"    => "ALL",
      "type"     => "database",
    }).must_equal(
      %(Argument "objs": ALL_IN_SCHEMA can be used only for type: table, sequence, function or procedure, database was passed.))
  end

  it "requires objs with Ansible's own wording" do
    privs_validation_msg({
      "login_db" => "postgres",
      "roles"    => "kpguser",
      "privs"    => "USAGE",
      "type"     => "schema",
    }).must_equal(%(Argument "objs" is required for type "schema".))
  end

  it "treats an empty privs string as not provided" do
    privs_validation_msg({
      "login_db" => "postgres",
      "objs"     => "sometable",
      "roles"    => "kpguser",
      "privs"    => "",
      "type"     => "table",
    }).must_equal(%(Argument "privs" is required for type "table".))
  end

  it "treats an empty schema string as not provided" do
    privs_validation_msg({
      "login_db" => "postgres",
      "objs"     => "kpgdb",
      "roles"    => "kpguser",
      "schema"   => "",
      "type"     => "database",
    }).must_equal(%(Argument "privs" is required for type "database".))
  end
end
