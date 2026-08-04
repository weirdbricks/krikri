#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # uri plugin (ansible.builtin.uri) - makes an HTTP request (API calls,
  # health checks, webhooks). Native HTTP::Client, same rationale as
  # get_url.cr's own doc comment: this plugin binary already runs on
  # whichever host (local or remote) the task targets, so no remote_exec
  # fallback is needed.
  #
  # Real Ansible's own uri module does NOT support check mode at all - even
  # a plain GET is skipped outright under --check ("This action (uri) does
  # not support check mode.", verified against a real ansible-playbook
  # --check run, not assumed) - so this doesn't special-case GET/HEAD the
  # way an initial reading of the docs might suggest; every method skips.
  # `changed:` is always false too (verified against the real module's
  # source - it isn't a stateful/idempotency-checking module, `dest:` file
  # writing aside, which isn't implemented here).
  class UriPlugin < BasePlugin
    MAX_REDIRECTS = 10

    def execute : PluginResult
      url = @params["url"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: url") unless url

      if is_true?(@params["check_mode"]?)
        return PluginResult.new(changed: false, failed: false, msg: "Skipped: uri module does not support check mode", skipped: true)
      end

      method = (@params["method"]? || "GET").upcase
      status_codes = (@params["status_code"]? || "200").split(",").map(&.strip.to_i)

      begin
        status, headers, body, redirected = request(url, method)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Request failed: #{ex.message}", url: url)
      end

      failed = !status_codes.includes?(status)
      msg = failed ? "Status code was #{status} and not #{status_codes}" : "OK (#{body.bytesize} bytes)"

      result = PluginResult.new(changed: false, failed: failed, msg: msg, url: url, status: status)
      apply_response_extras(result, headers, body, redirected)
      result
    end

    private def apply_response_extras(result : PluginResult, headers : HTTP::Headers, body : String, redirected : Bool)
      content_type = headers["Content-Type"]?.try(&.split(";").first.strip) || ""
      result.extra["content_type"] = JSON::Any.new(content_type)
      result.extra["redirected"] = JSON::Any.new(redirected)
      result.extra["location"] = JSON::Any.new(headers["Location"]) if headers["Location"]?

      if is_true?(@params["return_content"]?) || content_type == "application/json"
        result.extra["content"] = JSON::Any.new(body)
      end

      if content_type == "application/json"
        begin
          result.extra["json"] = JSON.parse(body)
        rescue
        end
      end
    end

    private def request(url : String, method : String, redirects_left : Int32 = MAX_REDIRECTS, redirected : Bool = false) : {Int32, HTTP::Headers, String, Bool}
      raise "too many redirects" if redirects_left < 0

      uri = URI.parse(url)
      client = build_client(uri)
      headers, body = request_headers_and_body

      response = client.exec(method, uri.request_target, headers: headers, body: body)

      if response.status.redirection? && (location = response.headers["Location"]?) && should_follow_redirect?(method)
        return request(resolve_redirect(uri, location), redirect_method(method, response.status_code), redirects_left - 1, true)
      end

      {response.status_code, response.headers, response.body, redirected}
    ensure
      client.try(&.close)
    end

    private def should_follow_redirect?(method : String) : Bool
      case @params["follow_redirects"]? || "safe"
      when "none", "no" then false
      when "safe"       then method == "GET" || method == "HEAD"
      else                   true
      end
    end

    # A 303 (or a 301/302 responding to POST) downgrades the redirected
    # request to GET, matching both real Ansible's underlying urllib
    # behavior and every browser's - a plain re-request of the same method
    # against a redirect target is not what a 303 means.
    private def redirect_method(method : String, status_code : Int32) : String
      (status_code == 303 || ((status_code == 301 || status_code == 302) && method == "POST")) ? "GET" : method
    end

    private def build_client(uri : URI) : HTTP::Client
      client = HTTP::Client.new(uri)

      timeout = (@params["timeout"]? || "30").to_i.seconds
      client.connect_timeout = timeout
      client.read_timeout = timeout

      if !is_true?(@params["validate_certs"]?, default: true) && (tls = client.tls?)
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end

      if (username = @params["url_username"]?) && (password = @params["url_password"]?)
        client.basic_auth(username, password)
      end

      client
    end

    private def request_headers_and_body : {HTTP::Headers, String?}
      headers = HTTP::Headers.new
      headers["User-Agent"] = @params["http_agent"]? || "ansible-httpget"

      if headers_param = @params["headers"]?
        Hash(String, JSON::Any).from_json(headers_param).each { |key, value| headers[key] = value.to_s }
      end

      body = @params["body"]?
      body_format = @params["body_format"]? || "raw"

      case body_format
      when "json"
        headers["Content-Type"] = "application/json" unless headers.has_key?("Content-Type")
      when "form-urlencoded"
        headers["Content-Type"] = "application/x-www-form-urlencoded" unless headers.has_key?("Content-Type")
        body = form_encode(body) if body
      end

      {headers, body}
    end

    # `body:` for form-urlencoded arrives as a JSON object (a YAML dict is
    # JSON-encoded by the playbook parser before any plugin sees it) -
    # re-encoded here as real application/x-www-form-urlencoded pairs
    # rather than passed through as literal JSON text.
    private def form_encode(body : String) : String
      fields = Hash(String, JSON::Any).from_json(body)
      URI::Params.build { |form| fields.each { |key, value| form.add(key, value.to_s) } }
    rescue
      body
    end

    private def resolve_redirect(base : URI, location : String) : String
      URI.parse(location).absolute? ? location : base.resolve(location).to_s
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::UriPlugin.new(config)
plugin.run
