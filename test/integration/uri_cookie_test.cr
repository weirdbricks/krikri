require "../minitest_helper"
require "http/server"

# Pins plugins/uri.cr's cookies/cookies_string result keys against real
# ansible-core 2.19.11 (live-verified via `{{ r | to_json }}` against a
# local Set-Cookie server): fetch_url parses its cookie jar into
# `cookies` (name -> value dict) and `cookies_string`
# ("name=value; name2=value2") on every response urllib returns
# normally - both keys ALWAYS present, empty dict/"" when no Set-Cookie
# came back, values kept byte-raw (a quoted value stays quoted in both
# keys), response order kept. The HTTPError leg of fetch_url (4xx/5xx
# and 304) never populates them, so a failed result carries neither.
# Key position: between the transmogrified response headers and msg
# (cookies_string first, then cookies - Ansible's info-dict insertion
# order).

COOKIE_TEST_SERVER = HTTP::Server.new do |context|
  response = context.response
  case context.request.path
  when "/set"
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.headers["Set-Cookie"] = "a=1; Path=/"
    response.headers.add("Set-Cookie", "b=2; Path=/")
    response.headers.add("Set-Cookie", "c=\"quoted\"; Path=/")
    response.print("cookie body")
  when "/redirect-then-set"
    response.status_code = 302
    response.headers["Location"] = "/set"
    response.headers["Set-Cookie"] = "hop=redirected; Path=/"
  when "/plain"
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.print("no cookies here")
  when "/ims-304"
    # Always 304 - real urllib raises HTTPError for it (no handler), so
    # fetch_url's jar-parsing lines never run.
    response.status_code = 304
  else
    response.status_code = 404
  end
end

COOKIE_TEST_ADDRESS = COOKIE_TEST_SERVER.bind_unused_port
spawn { COOKIE_TEST_SERVER.listen }
Fiber.yield

COOKIE_BASE = "http://#{COOKIE_TEST_ADDRESS}"

describe "uri plugin cookies" do
  it "returns cookies and cookies_string from Set-Cookie headers, values raw" do
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/set"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["cookies"].as_h["a"].as_s.must_equal("1")
    result["cookies"].as_h["b"].as_s.must_equal("2")
    # A quoted cookie value stays quoted - Ansible's cookiejar keeps the
    # raw value (live-verified: cookies_string 'c="quoted"').
    result["cookies"].as_h["c"].as_s.must_equal("\"quoted\"")
    result["cookies_string"].as_s.must_equal("a=1; b=2; c=\"quoted\"")
  end

  it "places cookies_string then cookies between the response headers and msg" do
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/set"})
    keys = result.as_h.keys

    set_cookie_index = keys.index("set_cookie")
    cs_index = keys.index("cookies_string")
    c_index = keys.index("cookies")
    msg_index = keys.index("msg")
    (set_cookie_index && cs_index && c_index && msg_index &&
      set_cookie_index < cs_index && cs_index < c_index && c_index < msg_index).must_equal(true)
  end

  it "carries an empty dict and empty string when no Set-Cookie came back" do
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/plain"})

    result["cookies"].as_h.size.must_equal(0)
    result["cookies_string"].as_s.must_equal("")
  end

  it "accumulates cookies set on a redirect hop" do
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/redirect-then-set"})

    result["cookies"].as_h["hop"].as_s.must_equal("redirected")
    result["cookies"].as_h["a"].as_s.must_equal("1")
    result["cookies_string"].as_s.must_equal("hop=redirected; a=1; b=2; c=\"quoted\"")
  end

  it "omits both keys on a failed (HTTPError-class) response" do
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/notfound"})

    result["failed"].as_bool.must_equal(true)
    result.as_h.has_key?("cookies").must_equal(false)
    result.as_h.has_key?("cookies_string").must_equal(false)
  end

  it "omits both keys on a 304 success" do
    # 304 raises urllib's HTTPError even when in status_code, so Ansible's
    # fetch_url never reaches the jar-parsing lines.
    result = PluginSpecHelper.run("uri", {"url" => "#{COOKIE_BASE}/ims-304", "status_code" => "304"})

    result["status"].as_i.must_equal(304)
    result.as_h.has_key?("cookies").must_equal(false)
    result.as_h.has_key?("cookies_string").must_equal(false)
  end
end
