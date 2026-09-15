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

  it "fails with real AnsibleModule's plural 'missing required arguments' when name is missing" do
    # podman-diff mysql_user_edge_cases W8: real community.mysql says
    # "missing required arguments: name" (plural even for one param);
    # this engine had the singular form.
    result = PluginSpecHelper.run("mysql_user", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "rejects an invalid state with real Ansible's choices message before any connection" do
    # podman-diff mysql_user_edge_cases W7: state: present-nowhere
    # previously fell through as if it were present and CREATED the
    # account (changed=true) where real Ansible fails the argument-spec
    # choices check before connecting (live-verified message).
    result = PluginSpecHelper.run("mysql_user", {
      "name"  => "alice",
      "state" => "present-nowhere",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, got: present-nowhere")
  end

  it "wraps a connection refusal in community.mysql's own message shape" do
    # podman-diff mysql_user_edge_cases W9: real community.mysql wraps
    # connect failures in its own "unable to connect to database, ..."
    # wording, not the generic "Could not connect to the MySQL server:"
    # shape (its PyMySQL (errno, "...") detail tail is library-specific
    # and not replicated).
    result = PluginSpecHelper.run("mysql_user", {
      "name"               => "alice",
      "login_unix_socket"  => "/run/krikri-no-such-mysql.sock",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("unable to connect to database, check login_user and login_password are correct or /root/.my.cnf has the credentials. Exception message: ")
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
      "name"               => "alice",
      "plugin"             => "AWSAuthenticationPlugin",
      "plugin_hash_string" => "hash1",
      "plugin_auth_string" => "hash2",
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
      "name"               => "alice",
      "plugin"             => "unix_socket",
      "plugin_hash_string" => "hash",
      "plugin_auth_string" => "other",
    })

    result["failed"].as_bool.should be_true
  end
end
