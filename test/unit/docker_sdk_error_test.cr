require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_sdk_error"

module Krikri
  module PluginHelpers
    # Regression tests for the Docker Python SDK's APIError wording that
    # real community.docker modules quote in their failure messages -
    # byte-verified against ansible-core 2.19.11 + community.docker 5.2.1
    # over a real daemon (podman's docker-compatible socket, API 1.41).
    # Pure message construction only - no daemon needed.
    describe DockerSdkError do
      describe ".api_error_text" do
        it "renders a 500 the way the SDK does, with the daemon's JSON message quoted" do
          DockerSdkError.api_error_text(500, "http+docker://localhost/v1.41/networks/create",
            "{\"message\": \"failed to find driver or plugin \\\"nosuchdriver\\\"\"}")
            .must_equal(%(500 Server Error for http+docker://localhost/v1.41/networks/create: Internal Server Error ("failed to find driver or plugin "nosuchdriver"")))
        end

        it "renders a 404 as a Client Error with the Not Found reason phrase" do
          DockerSdkError.api_error_text(404,
            "http+docker://localhost/v1.41/images/create?tag=kdw-nosuchtag&fromImage=docker.io%2Flibrary%2Fbusybox",
            %({"message": "manifest unknown: manifest unknown"}))
            .must_equal(%(404 Client Error for http+docker://localhost/v1.41/images/create?tag=kdw-nosuchtag&fromImage=docker.io%2Flibrary%2Fbusybox: Not Found ("manifest unknown: manifest unknown")))
        end

        it "falls back to the raw body when the daemon's body is not JSON" do
          DockerSdkError.api_error_text(500, "http+docker://localhost/v1.41/x", "boom")
            .must_equal(%(500 Server Error for http+docker://localhost/v1.41/x: Internal Server Error ("boom")))
        end

        it "omits the explanation entirely when the body carries no message" do
          DockerSdkError.api_error_text(500, "http+docker://localhost/v1.41/x", "")
            .must_equal("500 Server Error for http+docker://localhost/v1.41/x: Internal Server Error")
        end
      end

      describe ".status_reason" do
        it "spells out the reason phrase for the codes daemons answer with" do
          DockerSdkError.status_reason(500).must_equal("Internal Server Error")
          DockerSdkError.status_reason(404).must_equal("Not Found")
          DockerSdkError.status_reason(403).must_equal("Forbidden")
        end

        it "is empty for a code HTTP::Status does not know" do
          DockerSdkError.status_reason(999).must_equal("")
        end
      end

      describe ".daemon_message" do
        it "extracts the message field of a JSON error body" do
          DockerSdkError.daemon_message(%({"message": "no such network"})).must_equal("no such network")
        end

        it "returns the raw body for non-JSON bodies" do
          DockerSdkError.daemon_message("Not Found").must_equal("Not Found")
        end

        it "is nil for an empty body" do
          DockerSdkError.daemon_message("").must_be_nil
        end
      end

      describe ".api_error_text from a docr exception" do
        it "re-renders docr's Code/Message exception as the SDK's wording" do
          client = Docr::Client.new("/krikri-test-nonexistent.sock")
          client.last_request_url = "/networks/create"
          # docr's constructor itself prepends the "Code: NNN Message: "
          # prefix, so the daemon's own message goes in bare here.
          ex = Docr::Errors::DockerAPIError.new("failed to find driver or plugin \"nosuchdriver\"", 500)
          DockerSdkError.api_error_text(client,
            {"docker_host" => "unix:///run/user/1000/podman/podman.sock"} of String => String,
            ex, api_version: "1.41")
            .must_equal(%(500 Server Error for http+docker://localhost/v1.41/networks/create: Internal Server Error ("failed to find driver or plugin "nosuchdriver"")))
        end

        it "quotes a TCP daemon's base_url, not the http+docker placeholder" do
          client = Docr::Client.new("127.0.0.1", 2375)
          client.last_request_url = "/auth"
          ex = Docr::Errors::DockerAPIError.new("login failed", 500)
          DockerSdkError.api_error_text(client, {"docker_host" => "tcp://127.0.0.1:2375"} of String => String,
            ex, api_version: "1.41")
            .must_equal(%(500 Server Error for http://127.0.0.1:2375/v1.41/auth: Internal Server Error ("login failed")))
        end

        it "falls back to docr's own text when no request URL was recorded" do
          client = Docr::Client.new("/krikri-test-nonexistent.sock")
          ex = Docr::Errors::DockerAPIError.new("boom", 500)
          DockerSdkError.api_error_text(client, Hash(String, String).new, ex)
            .must_equal("Code: 500 Message: boom")
        end
      end

      describe ".form_url_encode" do
        it "percent-encodes a slash in a repository name like requests' urlencode" do
          DockerSdkError.form_url_encode("docker.io/library/busybox")
            .must_equal("docker.io%2Flibrary%2Fbusybox")
        end

        it "encodes a space the form way and leaves unreserved characters alone" do
          DockerSdkError.form_url_encode("a b-c.d_e~f").must_equal("a+b-c.d_e~f")
        end
      end
    end
  end
end
