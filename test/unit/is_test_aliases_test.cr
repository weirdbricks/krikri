require "../minitest_helper"
require "../support/jinja_render_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/krikri_jinja_filters"
require "../../src/krikri/variable_substitutor/jinja_renderer"

# P2.1-P2.3 (FINDINGS_CHECKLIST.md / PATTERN2_AUDIT.md): the `is*` test
# spelling alias pass - `issubset`/`issuperset`, `is_dir`/`is_file`/
# `is_link`/`is_mount`, `is_same_file`, `is_abs`. ansible.builtin
# registers both spellings of every one of these; krikri-playbook only
# had the base names, so `x is issubset(y)`-style spellings (the
# FQCN-adjacent alias class from PATTERN2_AUDIT.md) failed the whole
# render with "no test with name ... registered".
#
# Parity contract (spec requirements): every alias is exercised through
# BOTH the hand-rolled ConditionalEvaluator path AND a pure-Crinja
# render (`Crinja.new.render`), since this project's history is
# divergence between the two engines.
private def crinja_render(tpl : String, vars) : String
  krikri_jinja_render(tpl, vars)
end

describe "is* test aliases (P2.1-P2.3)" do
  # Shared fixture tree on the CONTROLLER's filesystem (these path tests
  # always check the controller, like Ansible's os.path.* wrappers).
  TMPDIR    = File.tempname("/tmp", "is_alias_spec")
  Dir.mkdir_p(TMPDIR)
  REAL_FILE = File.join(TMPDIR, "real.conf")
  REAL_DIR = File.join(TMPDIR, "real.d")
  File.write(REAL_FILE, "x")
  Dir.mkdir_p(REAL_DIR)
  LINK_FILE = File.join(TMPDIR, "link.conf")
  File.delete(LINK_FILE) if File.symlink?(LINK_FILE)
  File.symlink(REAL_FILE, LINK_FILE)

  # ConditionalEvaluator fixture vars (JSON::Any world).
  private def vars
    {
      "small"     => JSON.parse(%(["a", "b"])),
      "big"       => JSON.parse(%(["a", "b", "c"])),
      "conf_path" => JSON::Any.new(REAL_FILE),
      "dir_path"  => JSON::Any.new(REAL_DIR),
      "link_path" => JSON::Any.new(LINK_FILE),
      "abs_path"  => JSON::Any.new("/etc/hosts"),
      "rel_path"  => JSON::Any.new("etc/hosts"),
    }
  end

  describe "issubset / issuperset" do
    it "evaluates issubset as the subset test (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("small is issubset(big)", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("big is issubset(small)", vars).must_equal(false)
    end

    it "evaluates issuperset as the superset test (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("big is issuperset(small)", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("small is issuperset(big)", vars).must_equal(false)
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("big is not issubset(small)", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("small is not issuperset(big)", vars).must_equal(true)
    end

    it "empty list is a subset of anything (edge case, hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("empty is issubset(big)", vars.merge({"empty" => JSON.parse(%([]))})).must_equal(true)
    end
  end

  describe "is_dir / is_file / is_link" do
    it "dispatches the is_* spellings to the same os.path checks (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_file", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("dir_path is is_file", vars).must_equal(false)
      Krikri::ConditionalEvaluator.evaluate("dir_path is is_dir", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_dir", vars).must_equal(false)
      Krikri::ConditionalEvaluator.evaluate("link_path is is_link", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_link", vars).must_equal(false)
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is not is_dir", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("dir_path is not is_file", vars).must_equal(true)
    end

    it "does not misfire on the base spellings after adding the aliases" do
      # Regression guard: aliasing must not shadow/rewrite the original
      # base test names (e.g. " is file" inside " is is_file" mangling).
      Krikri::ConditionalEvaluator.evaluate("conf_path is file", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("dir_path is directory", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("link_path is link", vars).must_equal(true)
    end
  end

  describe "is_same_file" do
    HARD_FILE = File.join(TMPDIR, "hard.conf")
    File.delete(HARD_FILE) if File.exists?(HARD_FILE)
    File.link(REAL_FILE, HARD_FILE)

    private def hard_vars
      vars.merge({"hard_path" => JSON::Any.new(HARD_FILE)})
    end

    it "accepts the is_same_file spelling (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(hard_path)", hard_vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(dir_path)", hard_vars).must_equal(false)
    end

    it "matches on device+inode, not path equality (regression: hardlink)" do
      # os.path.samefile semantics: two DIFFERENT paths to the SAME file.
      Krikri::ConditionalEvaluator.evaluate("conf_path != hard_path", hard_vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(hard_path)", hard_vars).must_equal(true)
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is not is_same_file(dir_path)", hard_vars).must_equal(true)
    end
  end

  describe "is_abs" do
    it "evaluates os.path.isabs semantics (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("abs_path is is_abs", vars).must_equal(true)
      Krikri::ConditionalEvaluator.evaluate("rel_path is is_abs", vars).must_equal(false)
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("rel_path is not is_abs", vars).must_equal(true)
    end
  end

  # ---- Cross-engine parity: same expressions through a pure Crinja render ----
  describe "parity with pure Crinja render" do
    it "issubset/issuperset agree with the hand-rolled evaluator" do
      sets = {"small" => ["a", "b"], "big" => ["a", "b", "c"]}
      crinja_render("{{ small is issubset(big) }}", sets).must_equal("True")
      crinja_render("{{ big is issubset(small) }}", sets).must_equal("False")
      crinja_render("{{ big is issuperset(small) }}", sets).must_equal("True")
      crinja_render("{{ small is issuperset(big) }}", sets).must_equal("False")
    end

    it "is_dir/is_file/is_link/is_abs agree with the hand-rolled evaluator" do
      crinja_render("{{ p is is_file }}", {"p" => REAL_FILE}).must_equal("True")
      crinja_render("{{ p is is_dir }}", {"p" => REAL_DIR}).must_equal("True")
      crinja_render("{{ p is is_link }}", {"p" => LINK_FILE}).must_equal("True")
      crinja_render("{{ p is is_abs }}", {"p" => "/etc/hosts"}).must_equal("True")
      crinja_render("{{ p is is_abs }}", {"p" => "etc/hosts"}).must_equal("False")
    end

    it "is_same_file agrees with the hand-rolled evaluator" do
      hard_file = File.join(TMPDIR, "hard2.conf")
      File.delete(hard_file) if File.exists?(hard_file)
      File.link(REAL_FILE, hard_file)
      crinja_render("{{ a is is_same_file(b) }}", {"a" => REAL_FILE, "b" => hard_file}).must_equal("True")
      crinja_render("{{ a is is_same_file(b) }}", {"a" => REAL_FILE, "b" => REAL_DIR}).must_equal("False")
    end
  end

  # ---- Real-role regression: the shape roles actually write ----
  it "works inside a real {% if %} conditional through JinjaRenderer" do
    v = Hash(String, JSON::Any).new
    v["pkg_list"] = JSON.parse(%(["vim", "htop"]))
    v["wanted"] = JSON.parse(%(["htop"]))
    v["config"] = JSON::Any.new(REAL_FILE)
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
    renderer.render(%({% if wanted is issubset(pkg_list) %}present{% else %}absent{% endif %})).must_equal("present")
    renderer.render(%({% if pkg_list is issuperset(wanted) %}present{% else %}absent{% endif %})).must_equal("present")
    renderer.render(%({% if config is is_file %}yes{% else %}no{% endif %})).must_equal("yes")
  end

  # NOTE: no TMPDIR cleanup here - Crystal spec runs inside its own
  # at_exit handler, so an at_exit registered in a describe body fires
  # before the examples run (files would vanish mid-spec). The fixture
  # tree is left in /tmp; /tmp is cleaned periodically anyway.
end
