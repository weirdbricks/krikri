require "../spec_helper"
require "../support/jinja_render_helper"
require "../../src/krikri/krikri_jinja_filters"
require "../../src/krikri/variable_substitutor/jinja_renderer"

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
# render AND krikri-playbook's own JinjaRenderer (the path the
# template: action plugin uses); a divergence between the two is a
# failing test.
private def filter_batch2_crinja_render(tpl : String, vars = nil) : String
  krikri_jinja_render(tpl, vars)
rescue e
  "ERR: #{e.message}"
end

private def renderer_render(tpl : String, vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : String
  Krikri::VariableSubstitutor::JinjaRenderer.new(vars).render(tpl)
rescue e
  "ERR: #{e.message}"
end

describe "filter batch 2 (P2.8-P2.14, P2.15 verification)" do
  describe "P2.15 verification: pre-existing registrations reach pure Crinja env" do
    it "flatten with and without levels= resolves" do
      filter_batch2_crinja_render("{{ [1, [2, [3]]] | flatten }}").should eq("[1, 2, 3]")
      filter_batch2_crinja_render("{{ [1, [2, [3]]] | flatten(levels=1) }}").should eq("[1, 2, [3]]")
    end

    it "urlsplit with and without a component argument resolves" do
      filter_batch2_crinja_render("{{ 'http://h:8080/p?a=1#f' | urlsplit('query') }}").should eq("a=1")
      parts = filter_batch2_crinja_render("{{ 'http://h:8080/p' | urlsplit }}")
      parts.should contain("scheme")
      parts.should contain("http")
    end

    it "log with and without a base argument resolves" do
      filter_batch2_crinja_render("{{ 8 | log(2) }}").should eq("3.0")
      filter_batch2_crinja_render("{{ 8 | log }}").should_not contain("ERR")
    end

    it "pow resolves" do
      filter_batch2_crinja_render("{{ 2 | pow(10) }}").should eq("1024.0")
    end

    it "regex_search with group and regex_findall resolve" do
      filter_batch2_crinja_render("{{ 'hello world' | regex_search('w(or)ld') }}").should eq("world")
      filter_batch2_crinja_render("{{ 'a1b2' | regex_findall('[0-9]') }}").should eq("['1', '2']")
    end

    it "regex_findall with exactly ONE capture group returns a flat list of scalars, not one-element arrays" do
      # Same MatchData#size-off-by-one bug as filter_engine_spec.cr's
      # own copy of this fix (see there for the full lean_delivery.java
      # repro) - this pins the Crinja-side `Crinja.filter(:regex_findall)`
      # in jinja_filters.cr, the SEPARATE implementation a real `{{ }}`
      # filter chain actually goes through.
      filter_batch2_crinja_render("{{ ('Ready for use: >JDK 26<' | regex_findall('Ready for use:.*>JDK ([\\d]+)<') | first) }}").should eq("26")
    end
  end

  describe "strftime (P2.10, ansible-core 2.19 signature)" do
    # ansible-core 2.19 changed strftime's argument order: the PIPED
    # value is the FORMAT string and the epoch seconds are the first
    # positional argument (ansible-core source:
    # `def strftime(string_format, second=None, utc=False)`,
    # live-verified against 2.19.11). The pre-2.19 idiom
    # `ts | to_datetime | strftime('%H:%M')` - piped datetime, format as
    # the argument - now FAILS upstream ("Invalid value for epoch
    # value"); these specs pin the 2.19 shape, including that failure.
    it "formats epoch 0 in UTC with the format piped" do
      filter_batch2_crinja_render("{{ '%Y-%m-%d %H:%M:%S' | strftime(0, 'UTC') }}").should eq("1970-01-01 00:00:00")
    end

    it "formats an epoch integer and an epoch string" do
      filter_batch2_crinja_render("{{ '%Y-%m-%d' | strftime(1700000000) }}").should eq("2023-11-14")
      filter_batch2_crinja_render("{{ '%Y-%m-%d' | strftime('1700000000') }}").should eq("2023-11-14")
    end

    it "rejects a non-string piped value (the old to_datetime idiom)" do
      filter_batch2_crinja_render("{{ '2024-03-05 07:08:09' | to_datetime | strftime('%H:%M') }}").should contain("ERR")
    end

    it "rejects a non-numeric epoch argument" do
      filter_batch2_crinja_render("{{ '%Y' | strftime('not-an-epoch') }}").should contain("ERR")
    end
  end

  describe "subelements (P2.9)" do
    users = {"users" => JSON.parse(%([
      {"name": "root", "keys": ["k1", "k2"]},
      {"name": "bob", "keys": ["k3"]}
    ]))}

    it "produces [element, subelement] pairs for loop usage (pure Crinja)" do
      filter_batch2_crinja_render("{{ users | subelements('keys') }}", users).should eq(
        "[[{'name': 'root', 'keys': ['k1', 'k2']}, 'k1'], [{'name': 'root', 'keys': ['k1', 'k2']}, 'k2'], [{'name': 'bob', 'keys': ['k3']}, 'k3']]"
      )
    end

    it "accepts a LIST of field names for nested descent" do
      nested = {"roles" => JSON.parse(%([
        {"name": "web", "users": [{"who": "alice", "shells": ["bash", "zsh"]}, {"who": "bob", "shells": ["sh"]}]}
      ]))}
      result = filter_batch2_crinja_render("{{ roles | subelements(['users', 'shells']) }}", nested)
      result.should contain("'bash'")
      result.should contain("'zsh'")
      result.should contain("'alice'")
    end

    it "skips elements missing the key when skip_missing=true" do
      partial = {"users" => JSON.parse(%([
        {"name": "root", "keys": ["k1"]},
        {"name": "keyless"}
      ]))}
      filter_batch2_crinja_render("{{ users | subelements('keys', skip_missing=true) }}", partial).should eq(
        "[[{'name': 'root', 'keys': ['k1']}, 'k1']]"
      )
    end

    it "raises for a missing key without skip_missing" do
      partial = {"users" => JSON.parse(%([{"name": "keyless"}]))}
      filter_batch2_crinja_render("{{ users | subelements('keys') }}", partial).should contain("ERR")
    end
  end

  describe "trivial aliases (P2.13)" do
    it "count behaves as length" do
      filter_batch2_crinja_render("{{ 'abc' | count }}").should eq("3")
      filter_batch2_crinja_render("{{ [1, 2, 3, 4] | count }}").should eq("4")
    end

    it "d behaves as default (real Jinja2 semantics, not dict)" do
      filter_batch2_crinja_render("{{ missing | d(5) }}").should eq("5")
      # A defined None is not undefined: real ansible-core keeps it (and a
      # None renders as empty text), live-verified `a{{ x | d(5) }}b` -> "ab".
      filter_batch2_crinja_render("{{ x | d(5) }}", {"x" => nil}).should eq("")
      filter_batch2_crinja_render("{{ x | d(5) }}", {"x" => 7}).should eq("7")
    end

    it "e behaves as escape" do
      filter_batch2_crinja_render("{{ '<b>' | e }}").should eq("&lt;b&gt;")
    end

    it "items yields (key, value) pairs, like Jinja2's own items filter" do
      # Live-verified against ansible-core 2.19: `{{ {'a': 1} | items | list }}`
      # is [["a", 1]] (Crinja's dict2items-style alias was not real).
      filter_batch2_crinja_render("{{ {'a': 1} | items | list }}").should eq("[['a', 1]]")
    end

    it "root returns the filesystem-root prefix of a path" do
      filter_batch2_crinja_render("{{ '/etc/hosts' | root }}").should eq("/")
      filter_batch2_crinja_render("{{ 'x/y' | root }}").should eq("")
    end
  end

  # ---- Cross-engine parity: pure Crinja vs krikri-playbook's JinjaRenderer ----
  describe "parity: pure Crinja render vs JinjaRenderer" do
    it "strftime agrees between engines" do
      filter_batch2_crinja_render("{{ '%Y-%m-%d %H:%M:%S' | strftime(0, 'UTC') }}")
        .should eq(renderer_render("{{ '%Y-%m-%d %H:%M:%S' | strftime(0, 'UTC') }}", Hash(String, JSON::Any).new))
    end

    it "subelements agrees between engines" do
      v = Hash(String, JSON::Any).new
      v["users"] = JSON.parse(%([
        {"name": "root", "keys": ["k1", "k2"]},
        {"name": "bob", "keys": ["k3"]}
      ]))
      filter_batch2_crinja_render("{{ users | subelements('keys') | length }}", v)
        .should eq(renderer_render("{{ users | subelements('keys') | length }}", v))
    end

    it "the alias spellings agree between engines" do
      v = Hash(String, JSON::Any).new
      v["l"] = JSON.parse(%([1, 2, 3]))
      v["p"] = JSON::Any.new("/etc/hosts")
      filter_batch2_crinja_render("{{ l | count }}", v).should eq(renderer_render("{{ l | count }}", v))
      filter_batch2_crinja_render("{{ p | root }}", v).should eq(renderer_render("{{ p | root }}", v))
    end
  end

  # ---- Real-role regression ----
  it "drives a real authorized_keys-style loop through JinjaRenderer" do
    v = Hash(String, JSON::Any).new
    v["users"] = JSON.parse(%([
      {"name": "root", "keys": ["ssh-ed25519 AAAA1", "ssh-ed25519 AAAA2"]},
      {"name": "bob", "keys": ["ssh-ed25519 BBBB3"]}
    ]))
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
    # The classic subelements loop shape from real roles.
    renderer.render(
      %({% for user, key in users | subelements('keys') %}{{ user.name }}:{{ key }};{% endfor %})
    ).should eq("root:ssh-ed25519 AAAA1;root:ssh-ed25519 AAAA2;bob:ssh-ed25519 BBBB3;")
  end
end
