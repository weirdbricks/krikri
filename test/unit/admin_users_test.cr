require "../minitest_helper"
require "../../src/krikri/admin_users"

describe "Krikri::AdminUsers (admin_users_test.cr)" do
  it "defaults to ansible's root/toor when no variable sets the list" do
    Krikri::AdminUsers.resolve(nil, nil).must_equal(["root", "toor"])
    Krikri::AdminUsers.resolve({} of String => JSON::Any, {} of String => JSON::Any).must_equal(["root", "toor"])
  end

  it "reads a list variable (JSON/YAML inventory value) as the admin users" do
    vars = {"ansible_admin_users" => JSON::Any.new([JSON::Any.new("deploy")])}
    Krikri::AdminUsers.resolve(vars, nil).must_equal(["deploy"])
  end

  it "reads a comma-separated string variable the way ansible's list option does" do
    vars = {"ansible_admin_users" => JSON::Any.new("deploy, admin")}
    Krikri::AdminUsers.resolve(vars, nil).must_equal(["deploy", "admin"])
  end

  # A Jinja expression renders to Python's list repr, which is not JSON.
  it "reads a rendered template's list repr" do
    vars = {"ansible_admin_users" => JSON::Any.new("{{ ['deploy', 'admin'] }}")}
    Krikri::AdminUsers.resolve(vars, nil).must_equal(["deploy", "admin"])
  end

  it "falls back to the host's inventory vars when the task context does not set it" do
    host_vars = {"ansible_admin_users" => JSON::Any.new("deploy")}
    Krikri::AdminUsers.resolve({} of String => JSON::Any, host_vars).must_equal(["deploy"])
  end

  it "answers ansible's admin-user question for a connection user" do
    Krikri::AdminUsers.admin?(["root", "toor"], "root").must_equal(true)
    Krikri::AdminUsers.admin?(["root", "toor"], "deploy").must_equal(false)
    Krikri::AdminUsers.admin?(["root"], nil).must_equal(false)
  end
end
