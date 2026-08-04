require "../spec_helper"
require "http/server"

# A tiny local HTTP server exercising GET/POST/redirect/JSON/plain-text
# responses, started once for the whole file.
uri_test_server = HTTP::Server.new do |context|
  request = context.request
  response = context.response

  case {request.method, request.path}
  when {"GET", "/json"}
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.print(%({"ok":true,"n":5}))
  when {"GET", "/text"}
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.print("plain text body")
  when {"GET", "/notfound"}
    response.status_code = 404
  when {"GET", "/redirect"}
    response.status_code = 302
    response.headers["Location"] = "/text"
  when {"POST", "/echo"}
    body = request.body.try(&.gets_to_end) || ""
    response.status_code = 201
    response.headers["Content-Type"] = "application/json"
    response.print(%({"received":#{body.to_json}}))
  when {"POST", "/form"}
    body = request.body.try(&.gets_to_end) || ""
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.print(body)
  else
    response.status_code = 404
  end
end
uri_test_address = uri_test_server.bind_unused_port
spawn { uri_test_server.listen }
Fiber.yield

uri_base = "http://#{uri_test_address}"

describe "uri plugin" do
  it "requires url" do
    result = PluginSpecHelper.run("uri", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  it "performs a GET and does not include content by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["status"].as_i.should eq(200)
    result.as_h.has_key?("content").should be_false
  end

  it "includes content when return_content is set" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "return_content" => "true"})
    result["content"].as_s.should eq("plain text body")
  end

  it "always parses a json content-type into both content and json, regardless of return_content" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/json"})
    result["content"].as_s.should eq(%({"ok":true,"n":5}))
    result["json"]["ok"].as_bool.should be_true
    result["json"]["n"].as_i.should eq(5)
  end

  it "fails with a Status code message when the response isn't in status_code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/notfound"})
    result["failed"].as_bool.should be_true
    result["status"].as_i.should eq(404)
    result["msg"].as_s.should eq("Status code was 404 and not [200]")
  end

  it "accepts a custom status_code list" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/notfound", "status_code" => "404,410"})
    result["failed"].as_bool.should be_false
  end

  it "sends a POST body and reports the real status code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo", "method" => "POST", "body" => "hello", "status_code" => "201"})
    result["failed"].as_bool.should be_false
    result["status"].as_i.should eq(201)
    result["json"]["received"].as_s.should eq("hello")
  end

  it "form-encodes a dict body under body_format: form-urlencoded" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{uri_base}/form", "method" => "POST", "body" => %({"x":"1","y":"hello world"}),
      "body_format" => "form-urlencoded", "return_content" => "true",
    })
    content = result["content"].as_s
    content.should contain("x=1")
    content.should contain("y=hello+world")
  end

  it "follows a redirect by default and reports redirected: true" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/redirect", "return_content" => "true"})
    result["status"].as_i.should eq(200)
    result["redirected"].as_bool.should be_true
    result["content"].as_s.should eq("plain text body")
  end

  it "does not follow a redirect when follow_redirects: none" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/redirect", "follow_redirects" => "none"})
    result["status"].as_i.should eq(302)
    result["location"].as_s.should eq("/text")
    result["failed"].as_bool.should be_true
  end

  it "never reports changed, even for a mutating POST" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo", "method" => "POST", "status_code" => "201"})
    result["changed"].as_bool.should be_false
  end

  it "is skipped under check_mode regardless of method" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "check_mode" => "true"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
  end
end
