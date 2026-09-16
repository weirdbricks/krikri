#!/usr/bin/env crystal

require "json"
require "uri"
require "openssl"
require "http/client"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
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
  #   - the real module's AnsibleModule validation surface: state
  #     choices, parameters.py type conversion for timeout (int),
  #     insecure/compress/kerberos (bool) and headers/ovirt_auth (dict),
  #     required_if's state-absent-needs-ovirt_auth, and the
  #     "You must specify either 'url' or 'hostname'." check - which for
  #     state=absent reads url/hostname from the PREVIOUS ovirt_auth
  #     fact dict (with the same env fallbacks), the way the real module
  #     re-points `params` at that dict
  #
  # Deliberately left out: Kerberos authentication (the
  # token-http-auth/GSSNEGOTIATE grant - kerberos: true fails with an
  # explicit message rather than silently mis-authenticating) and the
  # `headers:` pass-through (the SDK threads them into every API call;
  # this module only ever talks to the token endpoints).
  class OvirtAuthPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # The real module's argument_spec in declaration order (no aliases).
    SPEC = {
      "url"        => [] of String,
      "hostname"   => [] of String,
      "username"   => [] of String,
      "password"   => [] of String,
      "ca_file"    => [] of String,
      "insecure"   => [] of String,
      "timeout"    => [] of String,
      "compress"   => [] of String,
      "kerberos"   => [] of String,
      "headers"    => [] of String,
      "state"      => [] of String,
      "token"      => [] of String,
      "ovirt_auth" => [] of String,
    }

    BOOL_PARAMS = {"insecure", "compress", "kerberos"}
    INT_PARAMS  = {"timeout"}
    DICT_PARAMS = {"headers", "ovirt_auth"}

    def execute : PluginResult
      state = @params["state"]? || "present"

      # Real AnsibleModule setup order (arg_spec.py's
      # ArgumentSpecValidator surfaces errors[0]): type conversion per
      # param in spec declaration order, state choices, required_if,
      # unsupported params - then the collection's check_sdk() gate
      # before the module body ever runs.
      if failure = validate_arg_types
        return failure
      end

      unless ["present", "absent"].includes?(state)
        return choices_error("state", ["present", "absent"], state)
      end

      # required_if: ('state', 'absent', ['ovirt_auth'])
      if state == "absent" && !@params["ovirt_auth"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is absent but all of the following are missing: ovirt_auth")
      end

      unsupported = unsupported_param_keys(@params, SPEC)
      unless unsupported.empty?
        return unsupported_params_error("ovirt.ovirt.ovirt_auth", unsupported, SPEC)
      end

      if failure = PluginHelpers::OvirtAuthCommand.sdk_gate
        return failure
      end

      if state == "absent"
        return revoke(@params["ovirt_auth"].not_nil!)
      end

      url = param_or_env("url", "OVIRT_URL")
      hostname = param_or_env("hostname", "OVIRT_HOSTNAME")
      return PluginResult.new(changed: false, failed: true,
        msg: "You must specify either 'url' or 'hostname'.") if url.nil? && hostname.nil?
      url = "https://#{hostname}/ovirt-engine/api" if url.nil?

      username = param_or_env("username", "OVIRT_USERNAME") || ""
      password = param_or_env("password", "OVIRT_PASSWORD") || ""
      token = param_or_env("token", "OVIRT_TOKEN")
      ca_file = param_or_env("ca_file", "OVIRT_CAFILE")

      insecure_param = @params["insecure"]?
      insecure = insecure_param ? true?(insecure_param) : !ca_file
      timeout = python_int(@params["timeout"]? || "0")
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

    # AnsibleModule's parameter.py type conversion, which runs before the
    # module body, per param in spec declaration order: timeout is int,
    # insecure/compress/kerberos are bool, headers/ovirt_auth are dict
    # (JSON object or k=v pairs). ca_file is type 'path' and the str
    # params never fail conversion, so neither can produce an error.
    private def validate_arg_types : PluginResult?
      SPEC.each_key do |param|
        value = @params[param]?
        next unless value
        if BOOL_PARAMS.includes?(param) && !bool_convertible?(value)
          return bool_type_error(param, value)
        end
        if INT_PARAMS.includes?(param) && !int_convertible?(value)
          return int_type_error(param, value)
        end
        if DICT_PARAMS.includes?(param) && !dict_param?(value)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to dict: " \
                 "dictionary requested, could not parse JSON or key=value")
        end
      end

      nil
    end

    # check_type_int semantics: a JSON int/bool/float converts (bool ->
    # 1/0, float truncates), but a string must be an integer literal -
    # int("not-a-number") is the TypeError that fails the module.
    def int_convertible?(raw : String) : Bool
      v = raw.strip
      return true if v.matches?(/^[+-]?\d+$/)
      return true if bool_convertible?(raw)
      return true if v.matches?(/[.eE]/) && !v.to_f64?.nil?
      false
    end

    private def python_int(raw : String?) : Int64
      return 0i64 unless raw
      v = raw.strip
      if v.matches?(/^[+-]?\d+$/)
        return v.to_i64? || 0i64
      end
      return v.downcase == "true" ? 1i64 : 0i64 if bool_convertible?(raw)
      (v.to_f64 || 0.0).to_i64
    rescue
      0i64
    end

    private def dict_param?(value : String) : Bool
      JSON.parse(value).as_h? != nil
    rescue
      value.includes?("=")
    end

    # state=absent: real module takes the previous run's ovirt_auth
    # fact, calls connection.close(logout=True) - revoking the token -
    # and exits with an empty ovirt_auth fact. The url/hostname (and
    # credential) resolution re-points at that dict, env vars as
    # fallback, exactly like the real module's params swap.
    private def revoke(raw : String) : PluginResult
      auth = JSON.parse(raw).as_h

      url = auth["url"]?.try(&.as_s?).presence || ENV["OVIRT_URL"]?
      hostname = auth["hostname"]?.try(&.as_s?).presence || ENV["OVIRT_HOSTNAME"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "You must specify either 'url' or 'hostname'.") if url.nil? && hostname.nil?
      url = "https://#{hostname}/ovirt-engine/api" if url.nil?

      token = auth["token"]?.try(&.as_s?).presence || ENV["OVIRT_TOKEN"]?
      ca_file = auth["ca_file"]?.try(&.as_s?).presence || ENV["OVIRT_CAFILE"]?
      insecure_fact = auth["insecure"]?.try(&.raw)
      insecure = insecure_fact.is_a?(Bool) ? insecure_fact : !ca_file

      unless token
        # no token in the fact: the real module's authenticate() falls
        # back to a fresh password-grant login with the dict/env creds
        username = auth["username"]?.try(&.as_s?).presence || ENV["OVIRT_USERNAME"]? || ""
        password = auth["password"]?.try(&.as_s?).presence || ENV["OVIRT_PASSWORD"]? || ""
        tok = request_token(url.not_nil!, username, password, ca_file, insecure)
        return tok if tok.is_a?(PluginResult)
        token = tok.as(String)
      end

      response = post_form(PluginHelpers::OvirtAuthCommand.sso_url(url.not_nil!, revoke: true),
        PluginHelpers::OvirtAuthCommand.revoke_body(token.not_nil!), ca_file, insecure)
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
