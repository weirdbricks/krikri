#!/usr/bin/env crystal

require "json"
require "uri"
require "openssl"
require "http/client"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ovirt_auth_command"

module Krikri
  # ovirt_auth plugin - a native port of ovirt.ovirt.ovirt_auth: logs
  # in to an oVirt/RHV engine and returns the `ovirt_auth` fact (SSO
  # token + connection settings) that every other oVirt module takes
  # as its `auth:` parameter; state=absent revokes a token.
  #
  # The real module drives the SSO flow through ovirt-engine-sdk-python
  # (pycurl); this port issues the same HTTP requests natively:
  #   - token: POST {scheme}://{netloc}/ovirt-engine/sso/oauth/token,
  #     form body grant_type=password&scope=ovirt-app-api&username=...
  #     &password=... (exact URL derivation of the SDK's
  #     _get_access_token: the API URL is stripped to scheme://netloc
  #     first, so https://host/ovirt-engine/api ->
  #     https://host/ovirt-engine/sso/oauth/token)
  #   - revoke (state=absent): POST
  #     {scheme}://{netloc}/ovirt-engine/services/sso-logout with
  #     scope=ovirt-app-api&token=... (the SDK's
  #     _revoke_access_token), triggered by passing the previous
  #     ovirt_auth fact - the same close(logout=True) the real module
  #     does in its finally block
  #   - `token:` short-circuits the login and is echoed into the fact
  #   - `insecure:` defaults to "not ca_file" like the real module;
  #     `hostname:` expands to https://<hostname>/ovirt-engine/api;
  #     OVIRT_URL/..._HOSTNAME/_USERNAME/_PASSWORD/_TOKEN/_CAFILE
  #     environment fallbacks honored
  #   - the SSO response error walk (OpenID-style
  #     error/error_description, then OAuth-style error_code/error)
  #     reproduces the SDK's _get_sso_error
  #
  # Deliberately left out: Kerberos authentication (the
  # token-http-auth/GSSNEGOTIATE grant - kerberos: true fails with an
  # explicit message rather than silently mis-authenticating) and the
  # `headers:` pass-through (the SDK threads them into every API call;
  # this module only ever talks to the token endpoints).
  class OvirtAuthPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]? || "present"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of state must be one of: present, absent, got #{state}") unless ["present", "absent"].includes?(state)

      if state == "absent"
        return revoke
      end

      url = param_or_env("url", "OVIRT_URL")
      hostname = param_or_env("hostname", "OVIRT_HOSTNAME")
      return PluginResult.new(changed: false, failed: true,
        msg: "You must specify either 'url' or 'hostname'.") if !url || url.empty?

      username = param_or_env("username", "OVIRT_USERNAME") || ""
      password = param_or_env("password", "OVIRT_PASSWORD") || ""
      token = param_or_env("token", "OVIRT_TOKEN")
      ca_file = param_or_env("ca_file", "OVIRT_CAFILE")

      insecure_param = @params["insecure"]?
      insecure = insecure_param ? true?(insecure_param) : !ca_file
      timeout = (@params["timeout"]? || "0").to_i? || 0
      compress = @params["compress"]? ? true?(@params["compress"]?, default: true) : true
      kerberos = true?(@params["kerberos"]?)

      if kerberos
        return PluginResult.new(changed: false, failed: true,
          msg: "kerberos authentication is not supported by this implementation")
      end

      if !token
        tok = request_token(url.not_nil!, username, password, ca_file, insecure)
        return tok if tok.is_a?(PluginResult)
        token = tok.as(String)
      end

      facts = {
        "token"    => JSON::Any.new(token.not_nil!),
        "url"      => JSON::Any.new(url.not_nil!),
        "ca_file"  => JSON::Any.new(ca_file),
        "insecure" => JSON::Any.new(insecure),
        "timeout"  => JSON::Any.new(timeout.to_i64),
        "compress" => JSON::Any.new(compress),
        "kerberos" => JSON::Any.new(kerberos),
      }
      PluginResult.new(changed: false, failed: false, msg: "Login to oVirt/RHV successful",
        ansible_facts: JSON::Any.new({"ovirt_auth" => JSON::Any.new(facts)}))
    end

    # state=absent: real module takes the previous run's ovirt_auth
    # fact, calls connection.close(logout=True) - revoking the token -
    # and exits with an empty ovirt_auth fact.
    private def revoke : PluginResult
      raw = @params["ovirt_auth"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "state is absent but all of the following are missing: ovirt_auth") unless raw

      begin
        auth = JSON.parse(raw).as_h
      rescue
        return PluginResult.new(changed: false, failed: true,
          msg: "ovirt_auth must be a dict with 'token' and 'url' entries")
      end
      token = auth["token"]?.try(&.as_s?)
      url = auth["url"]?.try(&.as_s?)
      return PluginResult.new(changed: false, failed: true,
        msg: "ovirt_auth must be a dict with 'token' and 'url' entries") unless token && url

      response = post_form(PluginHelpers::OvirtAuthCommand.sso_url(url, revoke: true),
        PluginHelpers::OvirtAuthCommand.revoke_body(token), nil, false)
      if response.is_a?(PluginResult)
        return response
      end

      PluginResult.new(changed: false, failed: false, msg: "Logout from oVirt/RHV successful",
        ansible_facts: JSON.parse(%({"ovirt_auth": {}})))
    end

    private def request_token(url : String, username : String, password : String,
                              ca_file : String?, insecure : Bool) : (String | PluginResult)
      response = post_form(PluginHelpers::OvirtAuthCommand.sso_url(url),
        PluginHelpers::OvirtAuthCommand.auth_body(username, password), ca_file, insecure)
      return response if response.is_a?(PluginResult)

      token, error = PluginHelpers::OvirtAuthCommand.extract_token(response.as(String))
      return PluginResult.new(changed: false, failed: true,
        msg: "Error during SSO authentication : #{error}") if error

      token.not_nil!
    end

    # The SDK's _get_sso_response: POST, form-encoded body,
    # Accept: application/json, TLS governed by insecure/ca_file.
    # Returns the response body as a String, or a failure result.
    private def post_form(url : String, body : String, ca_file : String?, insecure : Bool) : (String | PluginResult)
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      begin
        if uri.scheme == "https"
          if (tls = client.tls?)
            tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE if insecure
            tls.ca_certificates = ca_file if ca_file && !insecure
          end
        end
        response = client.post(uri.path + (uri.query ? "?#{uri.query}" : ""),
          HTTP::Headers{"Accept" => "application/json",
                         "Content-Type" => "application/x-www-form-urlencoded"},
          body)
        response.body
      rescue e
        PluginResult.new(changed: false, failed: true, msg: e.message || "HTTP request failed")
      ensure
        client.try(&.close)
      end
    end

    private def param_or_env(param : String, env_var : String) : String?
      @params[param]?.try(&.presence) || ENV[env_var]?
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::OvirtAuthPlugin.new(config)
plugin.run
