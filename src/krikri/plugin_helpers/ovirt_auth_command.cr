require "uri"

module Krikri
  module PluginHelpers
    # OvirtAuthCommand - the pure logic of ovirt.ovirt.ovirt_auth,
    # split out of the plugin so the SSO URL construction (identical
    # string manipulation to ovirtsdk4's _get_access_token /
    # _revoke_access_token, read from the SDK source), the OAuth form
    # body, and the token/revoke response parsing are unit-testable
    # without an oVirt engine. The plugin executes the HTTP calls.
    module OvirtAuthCommand
      SSO_TOKEN_PATH  = "/ovirt-engine/sso/oauth/token"
      SSO_REVOKE_PATH = "/ovirt-engine/services/sso-logout"

      # The SDK strips the API URL to scheme://netloc and appends the
      # fixed engine paths - anything before /ovirt-engine/api in the
      # path is dropped. (URI#host/#port is Crystal's netloc.)
      def self.sso_url(api_url : String, revoke : Bool = false) : String
        uri = URI.parse(api_url)
        netloc = uri.port ? "#{uri.host}:#{uri.port}" : uri.host.to_s
        base = "#{uri.scheme}://#{netloc}"
        revoke ? "#{base}#{SSO_REVOKE_PATH}" : "#{base}#{SSO_TOKEN_PATH}"
      end

      def self.hostname_to_url(hostname : String) : String
        "https://#{hostname}/ovirt-engine/api"
      end

      # _get_access_token's post_data (kerberos grant handled at the
      # plugin level - see the deliberate-limits note there).
      def self.auth_body(username : String, password : String) : String
        URI::Params.encode({
          "grant_type" => "password",
          "scope"      => "ovirt-app-api",
          "username"   => username,
          "password"   => password,
        })
      end

      def self.revoke_body(token : String) : String
        URI::Params.encode({
          "scope" => "ovirt-app-api",
          "token" => token,
        })
      end

      # _get_sso_response's error walk: OpenID-style
      # error/error_description first, then OAuth-style
      # error_code/error. Returns the access_token on success.
      def self.extract_token(response_body : String) : {String?, String?}
        json = JSON.parse(response_body)
        if json.as_h?
          if (desc = json["error_description"]?) && json["error"]?
            return {nil, "#{json["error"]} : #{desc.as_s}"}
          end
          if (code = json["error_code"]?) && json["error"]?
            return {nil, "#{code.as_s} : #{json["error"].as_s}"}
          end
          if (token = json["access_token"]?) && token.as_s?
            return {token.as_s, nil}
          end
        end
        {nil, "Unexpected SSO response"}
      rescue
        {nil, "Unexpected SSO response"}
      end
    end
  end
end
