require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"
require "../support/jinja_render_helper"
require "../../src/krikri/krikri_jinja_filters"

# version_type='pep440' semantics - packaging.Version's normalized PEP-440
# ordering, probed against ansible-core 2.19.11 by the orchestrator. Both
# evaluator copies (ConditionalEvaluator for `when:`/assert, the krikri-jinja
# registration for template files) share FilterCore.pep440_cmp; version_type=
# 'loose' (and the no-version_type default) keep their LooseVersion fallback.
describe "version test pep440 semantics" do
  private def core_pep440(a : String, b : String) : Int32
    Krikri::VariableSubstitutor::FilterCore.pep440_cmp(a, b)
  end

  private def when_eval(clause : String) : Bool
    Krikri::ConditionalEvaluator.evaluate(clause, {} of String => JSON::Any)
  end

  # The five facts probed against ansible-core 2.19.11.
  it "evaluates the five probed packaging comparison facts on the when side" do
    when_eval("'1.0.post1' is version('1.0', '>=', version_type='pep440')").must_equal(true)
    when_eval("'1!1.0' is version('2.0', '<', version_type='pep440')").must_equal(false)
    when_eval("'1.0rc1' is version('1.0', '<', version_type='pep440')").must_equal(true)
    when_eval("'1.0.dev4' is version('1.0rc1', '<', version_type='pep440')").must_equal(true)
    when_eval("'2.0.post1' is version('2.0', '==', version_type='pep440')").must_equal(false)
    when_eval("'2.0.post1' is version('2.0', '!=', version_type='pep440')").must_equal(true)
  end

  it "makes tags discriminate equality while releases normalize" do
    core_pep440("1.0", "1").must_equal(0)
    core_pep440("1.0.0", "1").must_equal(0)
    (core_pep440("2.0.post1", "2.0") > 0).must_equal(true)
    core_pep440("1.0rc1", "1.0-rc1").must_equal(0)
    core_pep440("1.0.0rc1", "1.0rc1").must_equal(0)
    core_pep440("v1.0", "1.0").must_equal(0)
    core_pep440(" 1.0 ", "1").must_equal(0)
    core_pep440(".1.0.", "1").must_equal(0)
  end

  it "ranks pre-tag spellings a/b/rc identically and dev before everything" do
    core_pep440("1.0-rc1", "1.0c1").must_equal(0)
    core_pep440("1.0preview", "1.0rc").must_equal(0)
    (core_pep440("1.0a1", "1.0b1") < 0).must_equal(true)
    (core_pep440("1.0b1", "1.0rc1") < 0).must_equal(true)
    core_pep440("1.0rc", "1.0rc0").must_equal(0)
    (core_pep440("1.0.dev4", "1.0rc1") < 0).must_equal(true)
    (core_pep440("1.0.dev4", "1.0") < 0).must_equal(true)
    (core_pep440("2.0.post1", "2.0.post1.dev1") > 0).must_equal(true)
    (core_pep440("1.0", "0.9.9.post9") > 0).must_equal(true)
  end

  it "orders epoch-major through the when evaluator" do
    when_eval("'1!1.0' is version('2.0', '>=', version_type='pep440')").must_equal(true)
    when_eval("'0!100.0' is version('1!0.0', '<', version_type='pep440')").must_equal(true)
  end

  it "routes a template-file render through the same comparator" do
    krikri_jinja_render("{{ '1.0.post1' is version('1.0', '>=', version_type='pep440') }}").must_equal("True")
    krikri_jinja_render("{{ '2.0.post1' is version('2.0', '==', version_type='pep440') }}").must_equal("False")
    krikri_jinja_render("{{ '1.0rc1' is version('1.0', '<', version_type='pep440') }}").must_equal("True")
  end

  it "keeps the loose version_type (and strict) unchanged" do
    when_eval("'1.0' is version('1.0.0', '==', version_type='loose')").must_equal(false)
    when_eval("'1.0' is version('1.0.0', '==', strict=True)").must_equal(true)
    when_eval("'2.0.post1' is version('2.0', '==', version_type='loose')").must_equal(false)
  end

  it "raises the probed invalid-version wording for the left operand" do
    assert_raises_message(
      Krikri::TestPluginError,
      "The test plugin 'ansible.builtin.version' failed: Version comparison failed: Invalid version: 'not-a-version'"
    ) do
      when_eval("'not-a-version' is version('1.0', '>=', version_type='pep440')")
    end
  end

  it "raises the probed invalid-version wording for the compare-to operand" do
    assert_raises_message(
      Krikri::TestPluginError,
      "Version comparison failed: Invalid version: 'not-a-version'"
    ) do
      when_eval("'1.0' is version('not-a-version', '>=', version_type='pep440')")
    end
  end

  it "raises the invalid-version wording through a template render" do
    assert_raises_message(
      KrikriJinja::TemplateError,
      "The test plugin 'ansible.builtin.version' failed: Version comparison failed: Invalid version: '1.0.xyz'"
    ) do
      krikri_jinja_render("{{ '1.0.xyz' is version('1.0', '>=', version_type='pep440') }}")
    end
  end
end
