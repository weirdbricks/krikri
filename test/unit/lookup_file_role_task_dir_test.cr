require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# Issue #308 (pgvillage.linux): a role task evaluates
# `when: query('file', tasks_file) | length > 0` with tasks_file
# "os-specifics-Debian.yml" and the file living in the role's OWN
# tasks/ dir (roles/<r>/tasks/os-specifics-Debian.yml). Ansible's file
# lookup probes the role root's files/ dir, the role root itself, and
# the directory of the task file doing the lookup (tasks/ for an
# ordinary role task) and returns the content; resolving every relative
# term against files/ only came back None instead, and the `| length`
# filter then died with "object of type 'NoneType' has no len()".
describe "lookup file role tasks/ dir search (issue #308)" do
  it "resolves a bare filename living in the role's own tasks/ dir, both evaluators" do
    role_dir = PluginSpecHelper.tmp_path("lookup_role_task_dir_role")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "os-specifics-Debian.yml"), "- name: hi\n  command: true\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)

    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', 'os-specifics-Debian.yml'))).must_equal("- name: hi\n  command: true")

    # The issue's literal shape: the role-side condition reads
    # query('file', tasks_file) | length > 0, tasks_file being a
    # variable, over the krikri-jinja route the when-condition takes.
    v["tasks_file"] = JSON::Any.new("os-specifics-Debian.yml")
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
    renderer.render("{{ query('file', tasks_file) | length > 0 }}").must_equal("True")
  end

  it "keeps files/ first over same-named role-root and tasks/ candidates" do
    role_dir = PluginSpecHelper.tmp_path("lookup_role_task_dir_ranking")
    Dir.mkdir_p(File.join(role_dir, "files"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "files", "probe.txt"), "from-files-dir\n")
    File.write(File.join(role_dir, "probe.txt"), "from-role-root\n")
    File.write(File.join(role_dir, "tasks", "only-in-tasks.txt"), "from-tasks-dir\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["tasks_file"] = JSON::Any.new("only-in-tasks.txt")

    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('file', 'probe.txt')").must_equal("from-files-dir")
    evaluator.evaluate("lookup('file', 'only-in-tasks.txt')").must_equal("from-tasks-dir")

    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
    renderer.render("{{ query('file', tasks_file) | length > 0 }}").must_equal("True")
  end
end
