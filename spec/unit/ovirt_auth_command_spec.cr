require "../spec_helper"
require "../../src/krikri/plugin_helpers/ovirt_auth_command"

# Unit-tests the ovirt_auth SSO plumbing against ovirtsdk4's own
# URL/body/error logic (read from the SDK source) - the plugin's HTTP
# paths need a live oVirt/RHV engine, the string shapes don't.
describe Krikri::PluginHelpers::OvirtAuthCommand do
  describe ".sso_url" do
    it "derives the token endpoint exactly like the SDK's _get_access_token" do
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api")
        .should eq("https://engine.example.com/ovirt-engine/sso/oauth/token")
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api")
        .should_not contain("/api/sso")
    end

    it "derives the revoke endpoint like the SDK's _revoke_access_token" do
      Krikri::PluginHelpers::OvirtAuthCommand.sso_url("https://engine.example.com/ovirt-engine/api", revoke: true)
        .should eq("https://engine.example.com/ovirt-engine/services/sso-logout")
    end
  end

  describe ".hostname_to_url" do
    it "expands a bare hostname to the engine API URL" do
      Krikri::PluginHelpers::OvirtAuthCommand.hostname_to_url("server.example.com")
        .should eq("https://server.example.com/ovirt-engine/api")
    end
  end

  describe ".auth_body / .revoke_body" do
    it "form-encodes the SDK's password-grant parameters" do
      body = Krikri::PluginHelpers::OvirtAuthCommand.auth_body("admin@internal", "s3cret")
      body.should contain("grant_type=password")
      body.should contain("scope=ovirt-app-api")
      body.should contain("username=admin%40internal")
      body.should contain("password=s3cret")
    end

    it "form-encodes the SDK's revoke parameters" do
      body = Krikri::PluginHelpers::OvirtAuthCommand.revoke_body("tok123")
      body.should contain("scope=ovirt-app-api")
      body.should contain("token=tok123")
    end
  end

  describe ".extract_token" do
    it "extracts access_token from a successful SSO response" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(%({"access_token": "tok", "token_type": "Bearer"}))
      error.should be_nil
      token.should eq("tok")
    end

    it "reports the OpenID-style error pair" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(
        %({"error": "invalid_grant", "error_description": "bad credentials"}))
      token.should be_nil
      error.should eq("invalid_grant : bad credentials")
    end

    it "reports the OAuth-style error pair" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token(
        %({"error_code": "ERR", "error": "denied"}))
      token.should be_nil
      error.should eq("ERR : denied")
    end

    it "treats non-JSON garbage as an unexpected response" do
      token, error = Krikri::PluginHelpers::OvirtAuthCommand.extract_token("<html>boom</html>")
      token.should be_nil
      error.should_not be_nil
    end
  end
end
