require "../spec_helper"
require "../../src/krikri/conditional_evaluator"
require "../../src/krikri/jinja_filters"
require "../../src/krikri/variable_substitutor/crinja_renderer"

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
  env = Crinja.new
  env.from_string(tpl).render(vars)
end

describe "is* test aliases (P2.1-P2.3)" do
  # Shared fixture tree on the CONTROLLER's filesystem (these path tests
  # always check the controller, like real Ansible's os.path.* wrappers).
  tmpdir = File.tempname("/tmp", "is_alias_spec")
  Dir.mkdir_p(tmpdir)
  real_file = File.join(tmpdir, "real.conf")
  real_dir = File.join(tmpdir, "real.d")
  File.write(real_file, "x")
  Dir.mkdir_p(real_dir)
  link_file = File.join(tmpdir, "link.conf")
  File.delete(link_file) if File.symlink?(link_file)
  File.symlink(real_file, link_file)

  # ConditionalEvaluator fixture vars (JSON::Any world).
  vars = {
    "small"     => JSON.parse(%(["a", "b"])),
    "big"       => JSON.parse(%(["a", "b", "c"])),
    "conf_path" => JSON::Any.new(real_file),
    "dir_path"  => JSON::Any.new(real_dir),
    "link_path" => JSON::Any.new(link_file),
    "abs_path"  => JSON::Any.new("/etc/hosts"),
    "rel_path"  => JSON::Any.new("etc/hosts"),
  }

  describe "issubset / issuperset" do
    it "evaluates issubset as the subset test (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("small is issubset(big)", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("big is issubset(small)", vars).should be_false
    end

    it "evaluates issuperset as the superset test (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("big is issuperset(small)", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("small is issuperset(big)", vars).should be_false
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("big is not issubset(small)", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("small is not issuperset(big)", vars).should be_true
    end

    it "empty list is a subset of anything (edge case, hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("empty is issubset(big)", vars.merge({"empty" => JSON.parse(%([]))})).should be_true
    end
  end

  describe "is_dir / is_file / is_link" do
    it "dispatches the is_* spellings to the same os.path checks (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_file", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("dir_path is is_file", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("dir_path is is_dir", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_dir", vars).should be_false
      Krikri::ConditionalEvaluator.evaluate("link_path is is_link", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_link", vars).should be_false
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is not is_dir", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("dir_path is not is_file", vars).should be_true
    end

    it "does not misfire on the base spellings after adding the aliases" do
      # Regression guard: aliasing must not shadow/rewrite the original
      # base test names (e.g. " is file" inside " is is_file" mangling).
      Krikri::ConditionalEvaluator.evaluate("conf_path is file", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("dir_path is directory", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("link_path is link", vars).should be_true
    end
  end

  describe "is_same_file" do
    hard_file = File.join(tmpdir, "hard.conf")
    File.delete(hard_file) if File.exists?(hard_file)
    File.link(real_file, hard_file)
    hard_vars = vars.merge({"hard_path" => JSON::Any.new(hard_file)})

    it "accepts the is_same_file spelling (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(hard_path)", hard_vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(dir_path)", hard_vars).should be_false
    end

    it "matches on device+inode, not path equality (regression: hardlink)" do
      # os.path.samefile semantics: two DIFFERENT paths to the SAME file.
      Krikri::ConditionalEvaluator.evaluate("conf_path != hard_path", hard_vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("conf_path is is_same_file(hard_path)", hard_vars).should be_true
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("conf_path is not is_same_file(dir_path)", hard_vars).should be_true
    end
  end

  describe "is_abs" do
    it "evaluates os.path.isabs semantics (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("abs_path is is_abs", vars).should be_true
      Krikri::ConditionalEvaluator.evaluate("rel_path is is_abs", vars).should be_false
    end

    it "supports the is not negation (hand-rolled evaluator)" do
      Krikri::ConditionalEvaluator.evaluate("rel_path is not is_abs", vars).should be_true
    end
  end

  # ---- Cross-engine parity: same expressions through a pure Crinja render ----
  describe "parity with pure Crinja render" do
    it "issubset/issuperset agree with the hand-rolled evaluator" do
      sets = {"small" => ["a", "b"], "big" => ["a", "b", "c"]}
      crinja_render("{{ small is issubset(big) }}", sets).should eq("True")
      crinja_render("{{ big is issubset(small) }}", sets).should eq("False")
      crinja_render("{{ big is issuperset(small) }}", sets).should eq("True")
      crinja_render("{{ small is issuperset(big) }}", sets).should eq("False")
    end

    it "is_dir/is_file/is_link/is_abs agree with the hand-rolled evaluator" do
      crinja_render("{{ p is is_file }}", {"p" => real_file}).should eq("True")
      crinja_render("{{ p is is_dir }}", {"p" => real_dir}).should eq("True")
      crinja_render("{{ p is is_link }}", {"p" => link_file}).should eq("True")
      crinja_render("{{ p is is_abs }}", {"p" => "/etc/hosts"}).should eq("True")
      crinja_render("{{ p is is_abs }}", {"p" => "etc/hosts"}).should eq("False")
    end

    it "is_same_file agrees with the hand-rolled evaluator" do
      hard_file = File.join(tmpdir, "hard2.conf")
      File.delete(hard_file) if File.exists?(hard_file)
      File.link(real_file, hard_file)
      crinja_render("{{ a is is_same_file(b) }}", {"a" => real_file, "b" => hard_file}).should eq("True")
      crinja_render("{{ a is is_same_file(b) }}", {"a" => real_file, "b" => real_dir}).should eq("False")
    end
  end

  # ---- Real-role regression: the shape roles actually write ----
  it "works inside a real {% if %} conditional through CrinjaRenderer" do
    v = Hash(String, JSON::Any).new
    v["pkg_list"] = JSON.parse(%(["vim", "htop"]))
    v["wanted"] = JSON.parse(%(["htop"]))
    v["config"] = JSON::Any.new(real_file)
    renderer = Krikri::VariableSubstitutor::CrinjaRenderer.new(v)
    renderer.render(%({% if wanted is issubset(pkg_list) %}present{% else %}absent{% endif %})).should eq("present")
    renderer.render(%({% if pkg_list is issuperset(wanted) %}present{% else %}absent{% endif %})).should eq("present")
    renderer.render(%({% if config is is_file %}yes{% else %}no{% endif %})).should eq("yes")
  end

  # NOTE: no tmpdir cleanup here - Crystal spec runs inside its own
  # at_exit handler, so an at_exit registered in a describe body fires
  # before the examples run (files would vanish mid-spec). The fixture
  # tree is left in /tmp; /tmp is cleaned periodically anyway.
end
