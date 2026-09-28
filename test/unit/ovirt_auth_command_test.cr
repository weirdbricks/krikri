require "../minitest_helper"
require "../../src/krikri/plugin_helpers/ovirt_auth_command"

# Unit-tests the ovirt_auth SSO plumbing against ovirtsdk4's own
# URL/body/error logic (read from the SDK source) - the plugin's HTTP
# paths need a live oVirt/RHV engine, the string shapes don't.
describe Krikri::PluginHelpers::OvirtAuthCommand do
  describe ".sdk_gate" do
    # Mirrors module_utils/ovirt.py's HAS_SDK probe: the gate passes
    # (nil) only when a host python can import ovirtsdk4 >= 4.4.0.
    it "fails with the collection's check_sdk message when ovirtsdk4 is missing" do
      gate = Krikri::PluginHelpers::OvirtAuthCommand.sdk_gate
      if gate
        gate.failed?.must_equal(true)
        gate.msg.must_equal("ovirtsdk4 version 4.4.0 or higher is required for this module")
      else
        # This host has the SDK installed - the probe passing is the
        # same behavior real Ansible shows on an SDK-equipped host.
        gate.must_be_nil
      end
    end
  end

  describe ".sso_url" do
    it "derives the token endpoint exactly like the SDK's _get_access_token" do
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api")
        .must_equal("https://engine.example.com/ovirt-engine/sso/oauth/token")
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api")
        .wont_include("/api/sso")
    end

    it "derives the revoke endpoint like the SDK's _revoke_access_token" do
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api", revoke: true)
        .must_equal("https://engine.example.com/ovirt-engine/services/sso-logout")
    end
  end

  describe ".hostname_to_url" do
    it "expands a bare hostname to the engine API URL" do
      Krikri::PluginHelpers::OvirtAuthCommand.hostname_to_url("server.example.com")
        .must_equal("https://server.example.com/ovirt-engine/api")
    end
  end

  describe ".auth_body / .revoke_body" do
    it "form-encodes the SDK's password-grant parameters" do
      body = Krikri::PluginHelpers::OvirtAuthCommand.auth_body("admin@internal", "s3cret")
      body.must_include("grant_type=password")
      body.must_include("scope=ovirt-app-api")
      body.must_include("username=admin%40internal")
      body.must_include("password=s3cret")
    end

    it "form-encodes the SDK's revoke parameters" do
      body = Krikri::PluginHelpers::OvirtAuthCommand.revoke_body("tok123")
      body.must_include("scope=ovirt-app-api")
      body.must_include("token=tok123")
    end
  end

  describe ".extract_token" do
    it "extracts access_token from a successful SSO response" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(%({"access_token": "tok", "token_type": "Bearer"}))
      error.must_be_nil
      token.must_equal("tok")
    end

    it "reports the OpenID-style error pair" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(
        %({"error": "invalid_grant", "error_description": "bad credentials"}))
      token.must_be_nil
      error.must_equal("invalid_grant : bad credentials")
    end

    it "reports the OAuth-style error pair" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(
        %({"error_code": "ERR", "error": "denied"}))
      token.must_be_nil
      error.must_equal("ERR : denied")
    end

    it "treats non-JSON garbage as an unexpected response" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token("<html>boom</html>")
      token.must_be_nil
      error.wont_be_nil
    end
  end
end
