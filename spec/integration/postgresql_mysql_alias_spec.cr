require "../spec_helper"

# Real bug found benchmarking robertdebock.postgres (round 43, 0.9.387):
# postgresql_db/postgresql_user/mysql_db/mysql_user all only ever read
# their own canonical `name:` param, never real Ansible's deprecated
# aliases (`db:` for postgresql_db/mysql_db, `user:` for postgresql_user/
# mysql_user) - a real playbook using either alias (the role's own
# "Create postgres database"/"Create postgres users" tasks do exactly
# this) always failed with "missing required argument: name" no matter
# what the alias was set to. No live DB server needed here - these
# exercise only the parameter-validation path that fails BEFORE any
# connection attempt, same approach as mysql_user_validation_spec.cr.
describe "postgresql_db/postgresql_user/mysql_db/mysql_user name: alias support" do
  it "postgresql_db accepts db: as an alias for name:" do
    result = PluginSpecHelper.run("postgresql_db", {"db" => "mydb"})
    result["msg"]?.try(&.as_s).should_not match(/missing required argument: name/)
  end

  it "postgresql_user accepts user: as an alias for name:" do
    result = PluginSpecHelper.run("postgresql_user", {"user" => "alice"})
    result["msg"]?.try(&.as_s).should_not match(/missing required argument: name/)
  end

  it "postgresql_user accepts db: as a deprecated alias for login_db:" do
    # Distinct from the name:/user: alias above - this is login_db:'s
    # own deprecated `db:` alias (robertdebock.postgres's own "Create
    # postgres users" task sets both `user:` AND `db:` on the same
    # task, for two entirely different params).
    result = PluginSpecHelper.run("postgresql_user", {"user" => "alice", "db" => "mydb"})
    result["msg"]?.try(&.as_s).should_not match(/missing required argument: name/)
  end

  it "mysql_db accepts db: as an alias for name:" do
    result = PluginSpecHelper.run("mysql_db", {"db" => "mydb"})
    result["msg"]?.try(&.as_s).should_not match(/missing required argument: name/)
  end

  it "mysql_user accepts user: as an alias for name:" do
    result = PluginSpecHelper.run("mysql_user", {"user" => "alice"})
    result["msg"]?.try(&.as_s).should_not match(/missing required argument: name/)
  end
end
