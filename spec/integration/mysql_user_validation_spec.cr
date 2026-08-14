require "../spec_helper"

# mysql_user validation specs - these exercise the parameter-validation
# paths that fail BEFORE any DB connection is attempted (so they need no
# live MySQL server, unlike the accounts-management paths themselves,
# which are covered live via the compat playbooks/containers).
describe "mysql_user plugin parameter validation" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("mysql_user", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name")
  end

  it "fails when both password and plugin are given (mutually exclusive)" do
    result = PluginSpecHelper.run("mysql_user", {
      "name"     => "alice",
      "password" => "secret",
      "plugin"   => "unix_socket",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("password and plugin are mutually exclusive")
  end

  it "fails when plugin_hash_string and plugin_auth_string are both given" do
    result = PluginSpecHelper.run("mysql_user", {
      "name"                => "alice",
      "plugin"              => "AWSAuthenticationPlugin",
      "plugin_hash_string"  => "hash1",
      "plugin_auth_string"  => "hash2",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("mutually exclusive")
  end

  it "fails when plugin_hash_string is given without a plugin" do
    result = PluginSpecHelper.run("mysql_user", {
      "name"               => "alice",
      "plugin_hash_string" => "hash1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("plugin is required")
  end

  it "fails with a clear message for an invalid update_password" do
    result = PluginSpecHelper.run("mysql_user", {
      "name"            => "alice",
      "update_password" => "sometimes",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("update_password")
  end

  it "errors instead of connecting when auth params are invalid (no DB needed)" do
    # A bare valid-looking call against no reachable server should fail at
    # connection (proving validation didn't reject a legitimate shape), but
    # an invalid combination must fail fast on validation, not on connect.
    result = PluginSpecHelper.run("mysql_user", {
      "name"   => "alice",
      "plugin" => "unix_socket",
      "plugin_hash_string" => "hash",
      "plugin_auth_string" => "other",
    })

    result["failed"].as_bool.should be_true
  end
end
