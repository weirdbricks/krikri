require "../minitest_helper"
require "http/server"
require "json"

# ansible.builtin.uri's `status_code:` is `type: list, elements: int`
# (default [200]). A role passing a TEMPLATED list - perimeterd.perimeterd's
# `status_code: "{{ range(100, 600) | list }}"`, round 5460281 - demotes to
# the stringified JSON array text "[100, 101, ...]" on the strings-only
# plugin wire; the plugin's old comma-split then hit the leading "[100"
# member and crashed the whole module with "Plugin execution failed:
# Invalid Int32: \"[100\"" BEFORE any request ran, which the role's
# block/rescue converted into its sanitized "controller network, TLS, or
# HTTP transport error" failure while real ansible-playbook 2.19.11 (which
# receives a genuine Python int list) made the same GitHub API request
# fine. These specs pin the JSON-array wire form, the plain string form,
# and the failure wording parity on a local HTTP server.

URI_STATUS_CODE_TEST_SERVER = HTTP::Server.new do |context|
  context.response.status_code = 200
  context.response.print("ok-body")
end
URI_STATUS_CODE_TEST_ADDRESS = URI_STATUS_CODE_TEST_SERVER.bind_unused_port
spawn { URI_STATUS_CODE_TEST_SERVER.listen }
Fiber.yield

URI_STATUS_CODE_TEST_URL = "http://127.0.0.1:#{URI_STATUS_CODE_TEST_ADDRESS.port}/"

describe "uri status_code list wire forms" do
  it "accepts a stringified JSON list of status codes (the templated-list wire form)" do
    result = PluginSpecHelper.run("uri", {
      "url"            => URI_STATUS_CODE_TEST_URL,
      "method"         => "GET",
      "status_code"    => "[100, 200, 404]",
      "return_content" => "true",
    })
    result["failed"]?.must_be_nil
    result["status"].must_equal(200)
    result["msg"].must_equal("OK (7 bytes)")
    result["content"].must_equal("ok-body")
  end

  it "keeps the plain comma-separated string form working" do
    result = PluginSpecHelper.run("uri", {
      "url"         => URI_STATUS_CODE_TEST_URL,
      "method"      => "GET",
      "status_code" => "200,404",
    })
    result["failed"]?.must_be_nil
    result["status"].must_equal(200)
  end

  it "keeps the bare scalar default (200) working" do
    result = PluginSpecHelper.run("uri", {
      "url"    => URI_STATUS_CODE_TEST_URL,
      "method" => "GET",
    })
    result["failed"]?.must_be_nil
    result["status"].must_equal(200)
  end

  it "still fails with Ansible's wording when the status is outside the JSON list" do
    result = PluginSpecHelper.run("uri", {
      "url"         => URI_STATUS_CODE_TEST_URL,
      "method"      => "GET",
      "status_code" => "[500]",
    })
    result["failed"]?.must_equal(true)
    result["status"].must_equal(200)
    result["msg"].must_equal("Status code was 200 and not [500]")
  end
end
