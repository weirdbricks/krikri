require "../spec_helper"
require "http/server"
require "../../src/crystal_play/variable_substitutor/expression_evaluator"

# A tiny local HTTP server (same pattern as get_url_spec.cr) serving a
# small multi-line checksums-style file plus a redirect, since real
# Ansible's own lookup('url', ...) usage (cloudalchemy.prometheus's
# checksum-pinning idiom) is exercised against URLs that redirect in
# practice (GitHub release assets 302 to a signed CDN URL).
URL_LOOKUP_BODY = "line one\nline two\nline three\n"

url_lookup_test_server = HTTP::Server.new do |context|
  case context.request.path
  when "/lines.txt"
    context.response.status_code = 200
    context.response.print(URL_LOOKUP_BODY)
  when "/redirect.txt"
    context.response.status_code = 302
    context.response.headers["Location"] = "/lines.txt"
  else
    context.response.status_code = 404
  end
end
url_lookup_test_address = url_lookup_test_server.bind_unused_port
spawn { url_lookup_test_server.listen }
Fiber.yield

url_lookup_base = "http://#{url_lookup_test_address}"

describe "lookup('url', ...)" do
  it "fetches a URL and returns its non-blank lines as a list" do
    # Real bug found benchmarking cloudalchemy.prometheus's own
    # checksum-pinning idiom: `lookup('url', '.../sha256sums.txt',
    # wantlist=True) | list`, then looping over each line looking for
    # the right architecture's checksum. lookup('url', ...) was entirely
    # unimplemented before - always "undefined".
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('url', '#{url_lookup_base}/lines.txt', wantlist=True)))
    JSON.parse(result).as_a.map(&.as_s).should eq(["line one", "line two", "line three"])
  end

  it "follows a redirect, matching how GitHub serves release assets" do
    # Crystal's HTTP::Client.get doesn't follow redirects on its own -
    # the very first real call this lookup was tested against (a GitHub
    # release URL) returned an empty 302 body instead of the checksums
    # file.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('url', '#{url_lookup_base}/redirect.txt', wantlist=True)))
    JSON.parse(result).as_a.map(&.as_s).should eq(["line one", "line two", "line three"])
  end

  it "supports a `+`-concatenated URL expression, real Ansible's own idiom for versioned release URLs" do
    v = Hash(String, JSON::Any).new
    v["path"] = JSON::Any.new("lines.txt")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('url', '#{url_lookup_base}/' + path, wantlist=True)))
    JSON.parse(result).as_a.map(&.as_s).should eq(["line one", "line two", "line three"])
  end

  it "returns a plain comma-joined string, not a JSON array, when wantlist=True is NOT given" do
    # Real bug found benchmarking robertdebock.kubectl (round 109):
    # `kubectl_url: ".../release/{{ lookup('url', kubectl_version_url)
    # }}/bin/linux/amd64/kubectl"` (the role's own vars/main.yml) calls
    # lookup('url', ...) with no wantlist=True at all - real Ansible's
    # own lookup() Jinja function only returns a real LIST when the
    # call site explicitly passes wantlist=True, otherwise it
    # comma-joins the plugin's own (always-list) result into a plain
    # STRING. This always returned the JSON-array form unconditionally,
    # so the literal text `["v1.31.0"]` got spliced into the URL
    # instead of the plain string `v1.31.0`, a 404.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('url', '#{url_lookup_base}/lines.txt')))
    result.should eq("line one,line two,line three")
  end

  it "raises on a 404, matching real Ansible's own url lookup plugin" do
    # Real bug found benchmarking buluma.victoriametrics (round 157): a
    # stale `victoriametrics_version` default whose GitHub release
    # checksums file has since been removed (404). Real ansible-playbook
    # fails the whole enclosing set_fact: task right at the lookup
    # ("The lookup plugin 'url' failed: Received HTTP error for <url> :
    # HTTP Error 404: Not Found") - this previously degraded silently
    # to "undefined" instead (this spec's own prior assertion, written
    # without live verification against real Ansible), letting
    # execution continue into a `with_items:` loop over a single bogus
    # "undefined" item and only fail several tasks later for an
    # unrelated reason - a real ok=/skipped= recap divergence from real
    # Ansible even though both engines ultimately failed the
    # broken-upstream role overall.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    expect_raises(Exception, /HTTP Error 404/) do
      evaluator.evaluate(%(lookup('url', '#{url_lookup_base}/missing.txt', wantlist=True)))
    end
  end
end
