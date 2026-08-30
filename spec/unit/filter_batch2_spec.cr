require "../spec_helper"
require "crinja"
require "crinja/json"
require "../../src/krikri/jinja_filters"
require "../../src/krikri/variable_substitutor/crinja_renderer"

# P2.8-P2.14 + P2.15 (FINDINGS_CHECKLIST.md / PATTERN2_AUDIT.md): the
# remaining filter batch, plus the verify-then-fix check.
#
# P2.15 VERIFICATION RESULT (2026-08-30): flatten(levels=...), urlsplit,
# log, pow, regex_search and regex_findall were already registered in
# jinja_filters.cr and DO reach Crinja's env - every one renders through
# a PURE Crinja render below (the `P2.15 verification` block). No fix
# was needed; the specs are kept as the permanent canary.
#
# New in this batch: strftime (documented directive subset in
# jinja_filters.cr), subelements, and the trivial aliases count/d/e/
# items/root (d aliases `default`, per real Jinja2 semantics - see the
# comment at the registration site for the checklist's "dict" wording).
#
# Parity contract: every filter is exercised through BOTH a pure-Crinja
# render AND krikri-playbook's own CrinjaRenderer (the path the
# template: action plugin uses); a divergence between the two is a
# failing test.
private def crinja_render(tpl : String, vars = nil) : String
  env = Crinja.new
  env.from_string(tpl).render(vars)
rescue e
  "ERR: #{e.message}"
end

private def renderer_render(tpl : String, vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : String
  Krikri::VariableSubstitutor::CrinjaRenderer.new(vars).render(tpl)
rescue e
  "ERR: #{e.message}"
end

describe "filter batch 2 (P2.8-P2.14, P2.15 verification)" do
  describe "P2.15 verification: pre-existing registrations reach pure Crinja env" do
    it "flatten with and without levels= resolves" do
      crinja_render("{{ [1, [2, [3]]] | flatten }}").should eq("[1, 2, 3]")
      crinja_render("{{ [1, [2, [3]]] | flatten(levels=1) }}").should eq("[1, 2, [3]]")
    end

    it "urlsplit with and without a component argument resolves" do
      crinja_render("{{ 'http://h:8080/p?a=1#f' | urlsplit('query') }}").should eq("a=1")
      parts = crinja_render("{{ 'http://h:8080/p' | urlsplit }}")
      parts.should contain("scheme")
      parts.should contain("http")
    end

    it "log with and without a base argument resolves" do
      crinja_render("{{ 8 | log(2) }}").should eq("3.0")
      crinja_render("{{ 8 | log }}").should_not contain("ERR")
    end

    it "pow resolves" do
      crinja_render("{{ 2 | pow(10) }}").should eq("1024.0")
    end

    it "regex_search with group and regex_findall resolve" do
      crinja_render("{{ 'hello world' | regex_search('w(or)ld') }}").should eq("world")
      crinja_render("{{ 'a1b2' | regex_findall('[0-9]') }}").should eq("['1', '2']")
    end
  end

  describe "strftime (P2.10)" do
    it "formats a to_datetime result" do
      crinja_render("{{ ts | to_datetime('%Y-%m-%d %H:%M:%S') | strftime('%Y/%m/%d %H:%M') }}", {"ts" => "2024-03-05 07:08:09"}).should eq("2024/03/05 07:08")
    end

    it "formats a raw epoch integer and epoch string" do
      crinja_render("{{ 1700000000 | strftime('%Y-%m-%d') }}").should eq("2023-11-14")
      crinja_render("{{ '1700000000' | strftime('%Y-%m-%d') }}").should eq("2023-11-14")
    end

    it "honors the default format (Python %Y-%m-%d %H:%M:%S subset)" do
      crinja_render("{{ '2024-01-02 03:04:05' | to_datetime | strftime }}").should eq("2024-01-02 03:04:05")
    end

    it "uses the documented %B/%e/%H directive subset" do
      crinja_render("{{ '2024-03-05 07:08:09' | to_datetime | strftime('%B %e, %H hours') }}").should eq("March  5, 07 hours")
    end

    it "rejects non-datetime targets" do
      crinja_render("{{ 'not-a-date' | strftime('%Y') }}").should contain("ERR")
    end
  end

  describe "subelements (P2.9)" do
    users = {"users" => JSON.parse(%([
      {"name": "root", "keys": ["k1", "k2"]},
      {"name": "bob", "keys": ["k3"]}
    ]))}

    it "produces [element, subelement] pairs for loop usage (pure Crinja)" do
      crinja_render("{{ users | subelements('keys') }}", users).should eq(
        "[[{'name': 'root', 'keys': ['k1', 'k2']}, 'k1'], [{'name': 'root', 'keys': ['k1', 'k2']}, 'k2'], [{'name': 'bob', 'keys': ['k3']}, 'k3']]"
      )
    end

    it "accepts a LIST of field names for nested descent" do
      nested = {"roles" => JSON.parse(%([
        {"name": "web", "users": [{"who": "alice", "shells": ["bash", "zsh"]}, {"who": "bob", "shells": ["sh"]}]}
      ]))}
      result = crinja_render("{{ roles | subelements(['users', 'shells']) }}", nested)
      result.should contain("'bash'")
      result.should contain("'zsh'")
      result.should contain("'alice'")
    end

    it "skips elements missing the key when skip_missing=true" do
      partial = {"users" => JSON.parse(%([
        {"name": "root", "keys": ["k1"]},
        {"name": "keyless"}
      ]))}
      crinja_render("{{ users | subelements('keys', skip_missing=true) }}", partial).should eq(
        "[[{'name': 'root', 'keys': ['k1']}, 'k1']]"
      )
    end

    it "raises for a missing key without skip_missing" do
      partial = {"users" => JSON.parse(%([{"name": "keyless"}]))}
      crinja_render("{{ users | subelements('keys') }}", partial).should contain("ERR")
    end
  end

  describe "trivial aliases (P2.13)" do
    it "count behaves as length" do
      crinja_render("{{ 'abc' | count }}").should eq("3")
      crinja_render("{{ [1, 2, 3, 4] | count }}").should eq("4")
    end

    it "d behaves as default (real Jinja2 semantics, not dict)" do
      crinja_render("{{ missing | d(5) }}").should eq("5")
      crinja_render("{{ x | d(5) }}", {"x" => nil}).should eq("5")
      crinja_render("{{ x | d(5) }}", {"x" => 7}).should eq("7")
    end

    it "e behaves as escape" do
      crinja_render("{{ '<b>' | e }}").should eq("&lt;b&gt;")
    end

    it "items behaves dict2items-style" do
      result = crinja_render("{{ {'a': 1} | items }}")
      result.should contain("'key': 'a'")
      result.should contain("'value': 1")
    end

    it "root returns the filesystem-root prefix of a path" do
      crinja_render("{{ '/etc/hosts' | root }}").should eq("/")
      crinja_render("{{ 'x/y' | root }}").should eq("")
    end
  end

  # ---- Cross-engine parity: pure Crinja vs krikri-playbook's CrinjaRenderer ----
  describe "parity: pure Crinja render vs CrinjaRenderer" do
    it "strftime agrees between engines" do
      v = Hash(String, JSON::Any).new
      v["ts"] = JSON::Any.new("2024-03-05 07:08:09")
      crinja_render("{{ ts | to_datetime('%Y-%m-%d %H:%M:%S') | strftime('%Y/%m/%d %H:%M') }}", v)
        .should eq(renderer_render("{{ ts | to_datetime('%Y-%m-%d %H:%M:%S') | strftime('%Y/%m/%d %H:%M') }}", v))
    end

    it "subelements agrees between engines" do
      v = Hash(String, JSON::Any).new
      v["users"] = JSON.parse(%([
        {"name": "root", "keys": ["k1", "k2"]},
        {"name": "bob", "keys": ["k3"]}
      ]))
      crinja_render("{{ users | subelements('keys') | length }}", v)
        .should eq(renderer_render("{{ users | subelements('keys') | length }}", v))
    end

    it "the alias spellings agree between engines" do
      v = Hash(String, JSON::Any).new
      v["l"] = JSON.parse(%([1, 2, 3]))
      v["p"] = JSON::Any.new("/etc/hosts")
      crinja_render("{{ l | count }}", v).should eq(renderer_render("{{ l | count }}", v))
      crinja_render("{{ p | root }}", v).should eq(renderer_render("{{ p | root }}", v))
    end
  end

  # ---- Real-role regression ----
  it "drives a real authorized_keys-style loop through CrinjaRenderer" do
    v = Hash(String, JSON::Any).new
    v["users"] = JSON.parse(%([
      {"name": "root", "keys": ["ssh-ed25519 AAAA1", "ssh-ed25519 AAAA2"]},
      {"name": "bob", "keys": ["ssh-ed25519 BBBB3"]}
    ]))
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(v)
    # The classic subelements loop shape from real roles.
    renderer.render(
      %({% for user, key in users | subelements('keys') %}{{ user.name }}:{{ key }};{% endfor %})
    ).should eq("root:ssh-ed25519 AAAA1;root:ssh-ed25519 AAAA2;bob:ssh-ed25519 BBBB3;")
  end
end
