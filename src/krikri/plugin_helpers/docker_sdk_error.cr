require "docr"
require "http/client"
require "json"

module Krikri
  module PluginHelpers
    # DockerSdkError - the Docker Python SDK's APIError rendering that
    # real community.docker modules quote in their failure messages:
    #
    #     500 Server Error for http+docker://localhost/v1.41/auth:
    #     Internal Server Error ("daemon's own message")
    #
    # `docr` words the same failure "Code: 500 Message: ..." and throws
    # away both the request URL and the status line's reason phrase, so
    # the plugins catch the error and re-render it here instead.
    # Previously only docker_container reproduced this wording inline;
    # every Docker module now shares it.
    module DockerSdkError
      # Raised for a pull the daemon rejected, so the failure message can
      # keep Ansible's own wording ("Error pulling image <ref> - ...")
      # instead of the generic API-error one.
      class ImagePullError < Exception
      end

      # `docr`'s client raises its DockerAPIError from deep inside its own
      # #call and keeps neither the request URL nor the reason phrase, so
      # the class is reopened here to remember the URL of the most recent
      # request. The body is docr's own #call (its client.cr) with the one
      # recording line added; the parameter types are deliberately NARROWER
      # than docr's (String url, String/nil body): Crystal's overload
      # resolution keeps docr's original def selected when a reopened
      # definition repeats its exact signature (defaults over a union
      # containing IO/Slice), so only a strictly more specific overload
      # reliably wins. Every docr endpoint calls with a String path and a
      # String/nil body, so they all route through this; the one exception
      # (the /build upload, whose body is an IO) falls back to docr's
      # original def and simply stays untraced.
      # `docr` calls every endpoint unversioned, but the SDK message always
      # quotes the versioned URL - api_version comes from a separate
      # /version round trip below.
      class ::Docr::Client
        property last_request_url : String = ""

        def call(method : String, url : String, headers : HTTP::Headers | Nil = nil, body : String | Nil = nil, &)
          @last_request_url = url
          exec(method, url, headers, body) do |response|
            unless response.success?
              response_body = response.body_io?.try(&.gets_to_end) || "{\"message\": \"No response body\"}"
              error = Docr::Types::ErrorResponse.from_json(response_body)
              raise Docr::Errors::DockerAPIError.new(error.message, response.status_code)
            end
            yield response
          end
        end
      end

      # The Docker Python SDK's APIError.__str__ (its errors.py): the
      # request line's own reason phrase, then the daemon's own message -
      # the `message` field of its JSON error body, or the raw body when
      # it isn't JSON - in quotes.
      def self.api_error_text(status : Int32, url : String, body : String) : String
        kind = 400 <= status < 500 ? "Client" : "Server"
        text = "#{status} #{kind} Error for #{url}: #{status_reason(status)}"
        explanation = daemon_message(body)
        explanation ? "#{text} (\"#{explanation}\")" : text
      end

      # Same rendering for a DockerAPIError raised by a traced client:
      # the URL is the one the failed request used (with the version
      # prefix the SDK always includes and docr never sends), and the
      # daemon's message is recovered from docr's "Code: NNN Message:
      # ..." exception text. Without a recorded URL (an error raised
      # before any request went out) there is nothing to re-render, and
      # docr's own text is the best available fallback.
      # api_version can be passed in by tests (which have no daemon to
      # negotiate with); nil means ask the daemon, like every real caller.
      def self.api_error_text(client : Docr::Client?, params : Hash(String, String), ex : Docr::Errors::DockerAPIError, api_version : String? = nil) : String
        # Captured BEFORE the /version negotiation below: that call goes
        # through the same traced client and overwrites last_request_url.
        url = client.try(&.last_request_url) || ""
        return ex.message || "" if url.empty? || client.nil?

        version = api_version || negotiated_api_version(client)
        base = "#{sdk_base_url(params, client)}/v#{version}"
        kind = 400 <= ex.status_code < 500 ? "Client" : "Server"
        "#{ex.status_code} #{kind} Error for #{base}#{url}: #{status_reason(ex.status_code)} (\"#{docr_daemon_message(ex)}\")"
      end

      # The status line's reason phrase, which Crystal's HTTP::Client
      # doesn't keep - its own HTTP::Status enum name is the closest
      # stand-in, and for the codes a Docker daemon actually answers with
      # ("Internal Server Error" on a 500) it is the very same text Ansible's
      # message quotes.
      def self.status_reason(status : Int32) : String
        text = HTTP::Status.new(status).to_s
        # An unknown code renders as its bare number - no reason phrase to
        # quote, same as the SDK seeing an unrecognized status line.
        return "" if text.matches?(/\A\d+\z/)

        text.split('_').map(&.capitalize).join(' ')
      rescue ArgumentError
        ""
      end

      def self.daemon_message(body : String) : String?
        return nil if body.strip.empty?

        parsed = JSON.parse(body).as_h?
        message = parsed.try { |fields| fields["message"]?.try { |value| value.as_s? } }
        message || body.strip
      rescue JSON::ParseException
        body.strip
      end

      # Ansible's SDK derives the API version it puts in every endpoint URL
      # from the daemon's own /version reply (its _retrieve_server_version),
      # which `docr` never asks for since it calls every endpoint
      # unversioned.
      def self.negotiated_api_version(client : Docr::Client) : String
        api_version = ""
        client.call("GET", "/version") do |response|
          api_version = JSON.parse(response.body_io.gets_to_end)["ApiVersion"].as_s
        end
        api_version
      end

      # Ansible's SDK base_url, the literal host part of every URL it quotes
      # in an error message: the http+docker:// placeholder it mounts its
      # UNIX-socket adapter under, or scheme://host:port for a TCP(+TLS)
      # daemon.
      def self.sdk_base_url(params : Hash(String, String), client : Docr::Client) : String
        docker_host = params["docker_host"]? || ENV["DOCKER_HOST"]?
        tcp = docker_host.try { |host| {"tcp://", "http://", "https://"}.any? { |scheme| host.starts_with?(scheme) } } || false
        return "http+docker://localhost" unless tcp

        "#{client.tls? ? "https" : "http"}://#{client.host}:#{client.port}"
      end

      # Real (both docker_container and docker_image pull through
      # AnsibleDockerClientBase.pull_image) POSTs the pull itself and wraps
      # any failure in its own prefix, so the wrapped text is the SDK's
      # APIError rendering. That URL is the versioned pull URL the SDK
      # builds - query in the SDK's own "tag=" then "fromImage=" order -
      # while `docr` calls every endpoint unversioned and orders its query
      # the other way round, so the pull goes out here directly to keep the
      # exact text Ansible reports.
      def self.pull_image!(client : Docr::Client, params : Hash(String, String), repository : String, tag : String, display_ref : String) : Nil
        query = "tag=#{form_url_encode(tag)}&fromImage=#{form_url_encode(repository)}"

        status = 0
        body = ""
        client.exec("POST", "/images/create?#{query}") do |response|
          status = response.status_code
          # The success body is a JSON progress STREAM - drain it to EOF
          # so the shared keep-alive connection's framing stays in sync.
          body = response.body_io?.try(&.gets_to_end) || ""
        end
        return if 200 <= status < 300

        # The versioned URL is only ever needed to render the failure, so
        # the extra /version round trip stays off the success path.
        request_url = "#{sdk_base_url(params, client)}/v#{negotiated_api_version(client)}/images/create?#{query}"
        raise ImagePullError.new("Error pulling image #{display_ref} - #{api_error_text(status, request_url, body)}")
      end

      # How Python's requests form-encodes a query value (its urlencode):
      # everything outside the unreserved set percent-encoded, so a `/` in
      # a repository name becomes %2F exactly like Ansible's own pull URL.
      def self.form_url_encode(value : String) : String
        String.build do |io|
          value.each_byte do |byte|
            char = byte.chr
            if char.ascii_alphanumeric? || "-._~".includes?(char)
              io << char
            elsif char == ' '
              io << '+'
            else
              io << '%' << byte.to_s(16).upcase.rjust(2, '0')
            end
          end
        end
      end

      # Real docker_login validates registry credentials with the daemon's
      # POST /auth (docker_login.py's _login) and quotes the SDK's APIError
      # text in its "Logging into ... failed - ..." failure. Returns nil
      # when the daemon accepted the credentials, otherwise that SDK text.
      def self.registry_auth_error(client : Docr::Client, params : Hash(String, String), registry_url : String, username : String, password : String) : String?
        body = {"username" => username, "password" => password, "email" => nil, "serveraddress" => registry_url}.to_json
        client.call("POST", "/auth", HTTP::Headers{"Content-Type" => "application/json"}, body) do |response|
          response.consume_body_io
        end
        nil
      rescue ex : Docr::Errors::DockerAPIError
        api_error_text(client, params, ex)
      end

      # The daemon's own message, recovered from docr's exception text
      # ("Code: 500 Message: <daemon message>" - docr's errors.cr).
      private def self.docr_daemon_message(ex : Docr::Errors::DockerAPIError) : String
        (ex.message || "").sub(/\ACode: \d+ Message: /, "")
      end
    end
  end
end
