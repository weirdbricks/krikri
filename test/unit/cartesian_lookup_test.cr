require "../minitest_helper"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_lookups"
require "../../src/krikri/krikri_jinja_filters"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_binary(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("cartesian-lookup", ".yml")
  File.write(playbook, pb)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: out_io, error: err_io)
  {status, out_io.to_s, err_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def qescaped(s : String) : String
  s.gsub('"', "\\\"")
end

describe "community.general cartesian lookup" do
  it "computes the probed 2x2 product through query() and q() in the hand-rolled evaluator" do
    # znerol.ssh_kba (round 5410000): query("cartesian", ...) degraded to
    # [] where ansible-core 2.19.11 + community.general 12.5.0 computes
    # the real product (live-verified grep of the module's own
    # listify_lookup_plugin_terms -> itertools.product -> _flatten chain).
    v = Hash(String, JSON::Any).new
    v["t1"] = JSON.parse(%(["a", "b"]))
    v["t2"] = JSON.parse(%(["k1", "k2"]))
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("query('cartesian', ['a','b'], ['k1','k2'])").must_equal(
      %([["a","k1"],["a","k2"],["b","k1"],["b","k2"]]))
    evaluator.evaluate("q('cartesian', ['a','b'], ['k1','k2'])").must_equal(
      %([["a","k1"],["a","k2"],["b","k1"],["b","k2"]]))
    # The rightmost list varies fastest (itertools.product ordering).
    evaluator.evaluate("query('cartesian', t1, t2)").must_equal(
      %([["a","k1"],["a","k2"],["b","k1"],["b","k2"]]))
    # The scalar spelling also stays a real list (live-verified 2.19.11:
    # lookup('cartesian', ...) returns the product list).
    evaluator.evaluate("lookup('cartesian', ['a','b'], ['k1','k2'])").must_equal(
      %([["a","k1"],["a","k2"],["b","k1"],["b","k2"]]))
  end

  it "renders the probed 2x2 product with real's data through the krikri-jinja engine" do
    KrikriJinja.render("{{ query('cartesian', ['a','b'], ['k1','k2']) }}", {} of String => JSON::Any).must_equal(
      "[['a', 'k1'], ['a', 'k2'], ['b', 'k1'], ['b', 'k2']]")
  end

  it "wraps string and scalar arguments as singletons, never iterating them" do
    # community.general's cartesian.py passes every term through
    # listify_lookup_plugin_terms: a string is IEnumerable in Python but
    # the free function explicitly wraps str terms as singletons - so
    # cartesian('ab', [...]) yields [['ab', ...]] rows, NOT 'a'/'b'
    # character rows (live-verified 2.19.11). Same for non-iterables
    # (int/bool/None); a dict is iterable, yielding its keys.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('cartesian', 'ab', ['k1','k2'])").must_equal(
      %([["ab","k1"],["ab","k2"]]))
    evaluator.evaluate("query('cartesian', 1, ['k1','k2'])").must_equal(
      %([[1,"k1"],[1,"k2"]]))
    KrikriJinja.render("{{ query('cartesian', 'ab', ['k1','k2']) }}", {} of String => JSON::Any).must_equal(
      "[['ab', 'k1'], ['ab', 'k2']]")
    KrikriJinja.render("{{ query('cartesian', 1, ['k1','k2']) }}", {} of String => JSON::Any).must_equal(
      "[[1, 'k1'], [1, 'k2']]")
  end

  it "collapses the whole product for an empty-list argument" do
    # itertools.product semantics: any empty argument makes the product
    # zero rows (live-verified 2.19.11: query('cartesian', ['a'], []) -> []).
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('cartesian', ['a'], [])").must_equal("[]")
    evaluator.evaluate("query('cartesian', ['a'], ['b','c'], [])").must_equal("[]")
    evaluator.evaluate("q('cartesian', ['a'], [])").must_equal("[]")
    KrikriJinja.render("{{ query('cartesian', ['a'], []) }}", {} of String => JSON::Any).must_equal("[]")
  end

  it "fails the template on zero arguments like the plugin's own error" do
    # cartesian.py raises AnsibleError("with_cartesian requires at least
    # one element in each list") when terms is empty - ansible-core 2.19
    # surfaces it as "Error while resolving value for '<key>': The
    # lookup plugin '...' failed: ..." and fails the task (live-verified
    # 2.19.11). The LookupError message prefix keeps the generic
    # "The lookup plugin '<name>' failed: ..." routing shape.
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::PythonLookupRunner::LookupError,
      "The lookup plugin 'cartesian' failed: with_cartesian requires at least one element in each list") do
      evaluator.evaluate("query('cartesian')")
    end
  end

  it "spreads nested-list elements one level into each row" do
    # LookupBase._flatten runs over each product tuple: nested list/tuple
    # elements extend into the row (one level), scalars append
    # (live-verified 2.19.11: cartesian([[1,2], 3], ['x','y']) ->
    # [[1, 2, 'x'], [1, 2, 'y'], [3, 'x'], [3, 'y']]).
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('cartesian', [[1,2], 3], ['x','y'])").must_equal(
      %([[1,2,"x"],[1,2,"y"],[3,"x"],[3,"y"]]))
    KrikriJinja.render("{{ query('cartesian', [[1,2], 3], ['x','y']) }}", {} of String => JSON::Any).must_equal(
      "[[1, 2, 'x'], [1, 2, 'y'], [3, 'x'], [3, 'y']]")
  end

  it "runs the full znerol chain to real's data through both engines and the when:/loop path" do
    # The exact znerol.ssh_kba shape (round 5410000, verified on real
    # ansible-core 2.19.11 by the orchestrator):
    #   cartesian -> map(first) -> list -> zip -> list
    # real data: NAMES ['a','a','b','b'] KEYS ['a k1','a k2','b k1','b k2']
    #            ZIP [['a','a k1'],...] LEN 4. The list LITERALS render
    # with each engine's own list convention (known shared limitation:
    # wantlist/query results render ["a","b"] vs real ['a','b'] in the
    # hand-rolled path) - the DATA must match, not the repr style.
    #
    # NOTE: minitest-safe and heredoc-indented; runs both engines end to
    # end against the real binary, including loop: + when: over the
    # product.
    status, out, _err = run_playbook_binary(<<-YAML
      - hosts: localhost
        gather_facts: false
        vars:
          _nxk: >-
            {{ query("cartesian", ['a','b'], ['k1','k2']) }}
          _nxk_names: >-
            {{ _nxk | map("first") | list }}
          _nxk_keys: >-
            {{ _nxk | map("join", " ") | list }}
          zipped: >-
            {{ _nxk_names | zip(_nxk_keys) | list }}
        tasks:
          - debug:
              msg: "NAMES|{{ _nxk_names }} KEYS|{{ _nxk_keys }} ZIP|{{ zipped }} LEN|{{ zipped | length }}"
          - debug:
              msg: "hit-{{ item }}"
            when: item[0] == 'b' and item[1] == 'k2'
            loop: "{{ query('cartesian', ['a','b'], ['k1','k2']) }}"
      YAML
    )
    combined = out + _err
    status.success?.must_equal(true, combined)
    out.must_include(qescaped(%(NAMES|["a","a","b","b"])))
    out.must_include(qescaped(%(KEYS|["a k1","a k2","b k1","b k2"])))
    out.must_include(qescaped(%(ZIP|[["a","a k1"],["a","a k2"],["b","b k1"],["b","b k2"]])) + " LEN|4")
    out.must_include("hit-['b', 'k2']")
  end
end
