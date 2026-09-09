require "../spec_helper"
require "crinja"
require "../../src/krikri/py_random"
require "../../src/krikri/jinja_filters"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/variable_substitutor/expression_evaluator"

# Regression specs for the two filters found missing in a real-host
# benchmark round (lean_delivery.jenkins_slave's `65534 | random(seed=
# inventory_hostname)` password generation and nephelaiio.packetbeat's
# `hosts | map('map_format', '%s:' + port) | list` output-host building).
private def s(value : String) : JSON::Any
  JSON::Any.new(value)
end

private def crinja_render(tpl : String, vars = nil) : String
  env = Crinja.new
  env.from_string(tpl).render(vars)
rescue e
  "ERR: #{e.message}"
end

describe Krikri::PyRandom do
  # Pinned against real CPython 3.13.5's random.Random (randrange goes
  # through _randbelow_with_getrandbits, identical across Python versions;
  # choice is the 3.11+ seq[_randbelow(len)] form) - these pin BIT-EXACT
  # parity with real ansible-playbook, not merely internal determinism.
  it "reproduces CPython's randrange for string seeds" do
    Krikri::PyRandom.new("host1").randrange(65534).should eq(31863)
    Krikri::PyRandom.new("host2").randrange(65534).should eq(58734)
  end

  it "reproduces CPython's randrange for integer seeds" do
    Krikri::PyRandom.new(12345).randrange(65534).should eq(27303)
  end

  it "reproduces CPython's choice for a string seed" do
    hosts = ["es1.example.com", "es2.example.com", "es3.example.com"]
    Krikri::PyRandom.new("host1").choice(hosts).should eq("es2.example.com")
  end
end

describe Krikri::VariableSubstitutor::FilterEngine do
  engine = Krikri::VariableSubstitutor::FilterEngine.new
  scoped = Krikri::VariableSubstitutor::FilterEngine.new({
    "inventory_hostname" => JSON::Any.new("host1"),
  } of String => JSON::Any)

  describe "random" do
    it "is a known filter name (the when: pre-pass must resolve it)" do
      Krikri::VariableSubstitutor::FilterEngine.known_filter_name?("random").should be_true
    end

    it "matches real Ansible for 65534 | random(seed=inventory_hostname)" do
      # lean_delivery.jenkins_slave's own password-generation idiom - the
      # seed is a VARIABLE reference (unquoted kwarg), not a literal.
      scoped.apply(JSON::Any.new(65534_i64), "random(seed=inventory_hostname)").as_i.should eq(31863)
    end

    it "matches real Ansible for a quoted string seed" do
      engine.apply(JSON::Any.new(65534_i64), "random(seed='host1')").as_i.should eq(31863)
    end

    it "is deterministic per seed (same seed twice -> same result)" do
      first = scoped.apply(JSON::Any.new(65534_i64), "random(seed=inventory_hostname)").as_i
      second = scoped.apply(JSON::Any.new(65534_i64), "random(seed=inventory_hostname)").as_i
      first.should eq(second)
    end

    it "gives different results for different seeds" do
      a = engine.apply(JSON::Any.new(65534_i64), "random(seed='host1')").as_i
      b = engine.apply(JSON::Any.new(65534_i64), "random(seed='host2')").as_i
      a.should_not eq(b)
    end

    it "returns an in-range int without a seed" do
      result = engine.apply(JSON::Any.new(65534_i64), "random").as_i
      result.should be >= 0
      result.should be < 65534
    end

    it "picks a list element deterministically per seed" do
      hosts = JSON::Any.new(["es1.example.com", "es2.example.com", "es3.example.com"].map { |host| JSON::Any.new(host) })
      first = engine.apply(hosts, "random(seed='host1')").as_s
      first.should eq("es2.example.com")
      engine.apply(hosts, "random(seed='host1')").as_s.should eq(first)
    end

    it "picks an unseeded list element from the list itself" do
      hosts = JSON::Any.new(["es1.example.com", "es2.example.com", "es3.example.com"].map { |host| JSON::Any.new(host) })
      picked = engine.apply(hosts, "random").as_s
      ["es1.example.com", "es2.example.com", "es3.example.com"].should contain(picked)
    end

    it "yields nil for an empty sequence (do_random's IndexError -> undefined)" do
      engine.apply(JSON::Any.new([] of JSON::Any), "random(seed='host1')").raw.should be_nil
    end
  end

  describe "map_format" do
    it "is a known filter name (the when: pre-pass must resolve it)" do
      Krikri::VariableSubstitutor::FilterEngine.known_filter_name?("map_format").should be_true
    end

    it "substitutes %s with the value" do
      engine.apply(s("host1"), %(map_format('%s:9200'))).as_s.should eq("host1:9200")
    end

    it "substitutes every %s occurrence with the value" do
      engine.apply(s("hello"), %(map_format('%s - %s'))).as_s.should eq("hello - hello")
    end

    it "honors Python's %% escape" do
      engine.apply(s("x"), %(map_format('100%% %s'))).as_s.should eq("100% x")
    end

    it "works through map() the way the packetbeat role calls it" do
      hosts = JSON::Any.new(["es1", "es2"].map { |host| JSON::Any.new(host) })
      result = engine.apply_chain(hosts, %(map('map_format', '%s:9200') | list))
      result.as_a.map(&.as_s).should eq(["es1:9200", "es2:9200"])
    end

    it "stringifies a dict item (the real plugin's % operator on a non-mapping value)" do
      # The real plugin does `pattern % tuple([value] * count)` - a dict
      # item is NOT a mapping lookup, it is one str()'d value. krikri's
      # str() convention for containers is JSON repr (FilterEngine#as_string).
      item = JSON::Any.new({"host" => s("es1")} of String => JSON::Any)
      engine.apply(item, %(map_format('%s='))).as_s.should eq(%({"host":"es1"}=))
      # and a %{key}-placeholder pattern has no %s to substitute: the real
      # plugin returns the pattern unchanged (empty tuple % - format).
      engine.apply(item, %(map_format('%{host}=%{port}'))).as_s.should eq("%{host}=%{port}")
    end

    it "applies the dict/dict form per key, defaulting missing patterns to %s" do
      value = JSON::Any.new({
        "a" => s("x"),
        "b" => s("y"),
      } of String => JSON::Any)
      result = engine.apply(value, "map_format({'a': '%s!'})")
      result.as_h["a"].as_s.should eq("x!")
      result.as_h["b"].as_s.should eq("y")
    end

    it "leaves the value unchanged with no pattern argument" do
      engine.apply(s("host1"), "map_format").as_s.should eq("host1")
    end
  end

  describe "Crinja side (.j2 templates / {% %} blocks)" do
    it "random with a seed matches real Ansible through a pure Crinja render" do
      crinja_render("{{ 65534 | random(seed='host1') }}").should eq("31863")
      crinja_render("{{ n | random(seed=host) }}", {"n" => 65534, "host" => "host1"}).should eq("31863")
    end

    it "random picks a list element deterministically per seed" do
      hosts = ["es1.example.com", "es2.example.com", "es3.example.com"]
      first = crinja_render("{{ hosts | random(seed='host1') }}", {"hosts" => hosts})
      first.should eq("es2.example.com")
      crinja_render("{{ hosts | random(seed='host1') }}", {"hosts" => hosts}).should eq(first)
    end

    it "map_format reaches the Crinja env via the role's map('map_format', ...) shape" do
      crinja_render(
        "{{ hosts | map('map_format', '%s:9200') | join(',') }}",
        {"hosts" => ["es1", "es2"]}
      ).should eq("es1:9200,es2:9200")
    end
  end
end
