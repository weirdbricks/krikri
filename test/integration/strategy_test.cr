require "file_utils"
require "../minitest_helper"

# `strategy:` - linear (the default, and this engine's existing
# behavior) versus free, where each host runs the WHOLE task list
# independently with no barrier between tasks. Expectations captured
# from ansible-core 2.19.4 with h1 deliberately sleeping in the first
# task, which is what makes the difference observable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_strategy(strategy : String?, plugin : String? = nil, plugin_env : Bool = false) : {Int32, Array(String)}
  dir = File.tempname("strategy")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\n")
  # A strategy plugin dir is either the playbook-adjacent one Ansible's
  # loader searches first or an explicit ANSIBLE_STRATEGY_PLUGINS entry.
  # The content never matters here: this engine resolves the plugin's
  # NAME but cannot execute Python strategy code (issue #1439).
  plugin_dir = plugin_env ? File.join(dir, "plugin_env") : File.join(dir, "strategy_plugins")
  if plugin_name = plugin
    Dir.mkdir_p(plugin_dir)
    File.write(File.join(plugin_dir, "#{plugin_name}.py"), "")
  end
  line = strategy ? "  strategy: #{strategy}\n" : ""
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{line.rstrip}
      tasks:
        - name: slow on h1
          ansible.builtin.command: sh -c "test '{{ inventory_hostname }}' = h1 && sleep 1; echo A"
        - name: second
          ansible.builtin.command: echo B
    YAML

  stdout_io = IO::Memory.new
  env = plugin_env ? {"ANSIBLE_STRATEGY_PLUGINS" => plugin_dir} : nil
  status = Process.run(BINARY, ["-i", "inv.ini", "-f", "5", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir, env: env)
  # The banner/result sequence IS the observable difference.
  lines = stdout_io.to_s.lines.compact_map do |lv2|
    if lv2.starts_with?("TASK [")
      # Ansible's banner pads the line with "*" to the display width;
      # strip the padding so the sequence assertions stay name-only.
      lv2.sub(/ \*+$/, "")
    elsif lv2 =~ /^(changed|ok): \[(h\d)\]/
      "#{$1}:#{$2}"
    end
  end
  {status.exit_code, lines}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "strategy:" do
  # linear: one banner per task, both hosts under it - there is a
  # barrier, so nobody starts task 2 until everyone finished task 1.
  it "keeps a barrier between tasks by default" do
    code, lines = run_strategy(nil)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
    (lines.index!("TASK [second]") > lines.index!("changed:h1")).must_equal(true)
  end

  it "behaves the same for an explicit linear" do
    _, lines = run_strategy("linear")
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # free: h2 races through BOTH its tasks while h1 is still sleeping in
  # the first, so each host gets its own banner sequence and h2's second
  # task is reported before h1's first.
  it "lets a fast host run ahead with free" do
    code, lines = run_strategy("free")
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(2)
    lines.must_equal([
      "TASK [slow on h1]", "changed:h2",
      "TASK [second]", "changed:h2",
      "TASK [slow on h1]", "changed:h1",
      "TASK [second]", "changed:h1",
    ])
  end

  # host_pinned differs from free only in worker affinity, which this
  # engine has no equivalent of.
  it "treats host_pinned as free" do
    _, lines = run_strategy("host_pinned")
    lines.count(&.starts_with?("TASK [slow")).must_equal(2)
  end

  # Ansible REFUSES an unknown strategy - it does not fall back to
  # linear - and exits 1, not the parser-error 4.
  it "refuses an unknown strategy" do
    code, _ = run_strategy("nonsense")
    code.must_equal(1)
  end

  # `debug` is Ansible's interactive debugger strategy - linear plus a
  # stdin prompt only when a task fails - so a run with no failure
  # prints ordinary linear output (live-verified vs ansible-core
  # 2.21.6, issue #1439).
  it "runs the built-in debug strategy as linear" do
    code, lines = run_strategy("debug")
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
    (lines.index!("TASK [second]") > lines.index!("changed:h1")).must_equal(true)
  end

  # A strategy plugin beside the playbook is accepted (Ansible's loader
  # searches `strategy_plugins/` first) and runs as linear, since this
  # engine cannot execute Python strategy code (issue #1439).
  it "accepts a playbook-local strategy plugin" do
    code, lines = run_strategy("custom_demo", plugin: "custom_demo")
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # Same through ANSIBLE_STRATEGY_PLUGINS, the path the issue's repro
  # uses. Passed as a child env so no process-wide ENV is touched.
  it "accepts a strategy plugin from ANSIBLE_STRATEGY_PLUGINS" do
    code, lines = run_strategy("custom_demo", plugin: "custom_demo", plugin_env: true)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end
end
