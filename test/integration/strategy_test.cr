require "file_utils"
require "../minitest_helper"

# `strategy:` - linear (the default, and this engine's existing
# behavior) versus free, where each host runs the WHOLE task list
# independently with no barrier between tasks. ANSIBLE_STRATEGY is the
# same setting's default, so covering both matters. Expectations captured
# from ansible-core 2.19.4/2.21.6 with h1 deliberately sleeping in the
# first task, which is what makes the difference observable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_strategy(strategy : String?, plugin : String? = nil, plugin_env : Bool = false,
                         env : Hash(String, String?) = {} of String => String?,
                         playbook_subdir : String? = nil,
                         relative_plugin_env : Bool = false) : {Int32, Array(String), String}
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
  playbook_rel = playbook_subdir ? File.join(playbook_subdir, "pb.yml") : "pb.yml"
  Dir.mkdir_p(File.dirname(File.join(dir, playbook_rel)))
  File.write(File.join(dir, playbook_rel), <<-YAML)
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
  # Pin ANSIBLE_STRATEGY as unset unless a test supplies it, so a
  # developer's own exported value cannot change these expectations.
  child_env = {"ANSIBLE_STRATEGY" => nil}.merge(env)
  if plugin_env
    child_env["ANSIBLE_STRATEGY_PLUGINS"] = relative_plugin_env ? "./plugin_env" : plugin_dir
  end
  status = Process.run(BINARY, ["-i", "inv.ini", "-f", "5", playbook_rel],
    output: stdout_io, error: stdout_io, chdir: dir, env: child_env)
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
  {status.exit_code, lines, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "strategy:" do
  # linear: one banner per task, both hosts under it - there is a
  # barrier, so nobody starts task 2 until everyone finished task 1.
  it "keeps a barrier between tasks by default" do
    code, lines, _ = run_strategy(nil)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
    (lines.index!("TASK [second]") > lines.index!("changed:h1")).must_equal(true)
  end

  it "behaves the same for an explicit linear" do
    _, lines, _ = run_strategy("linear")
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # free: h2 races through BOTH its tasks while h1 is still sleeping in
  # the first, so each host gets its own banner sequence and h2's second
  # task is reported before h1's first.
  it "lets a fast host run ahead with free" do
    code, lines, _ = run_strategy("free")
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
    _, lines, _ = run_strategy("host_pinned")
    lines.count(&.starts_with?("TASK [slow")).must_equal(2)
  end

  # Ansible REFUSES an unknown strategy - it does not fall back to
  # linear - and exits 1, not the parser-error 4.
  it "refuses an unknown strategy" do
    code, _, _ = run_strategy("nonsense")
    code.must_equal(1)
  end

  # `debug` is Ansible's interactive debugger strategy - linear plus a
  # stdin prompt only when a task fails - so a run with no failure
  # prints ordinary linear output (live-verified vs ansible-core
  # 2.21.6, issue #1439).
  it "runs the built-in debug strategy as linear" do
    code, lines, _ = run_strategy("debug")
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
    (lines.index!("TASK [second]") > lines.index!("changed:h1")).must_equal(true)
  end

  # A strategy plugin beside the playbook is accepted (Ansible's loader
  # searches `strategy_plugins/` first) and runs as linear, since this
  # engine cannot execute Python strategy code (issue #1439).
  it "accepts a playbook-local strategy plugin" do
    code, lines, _ = run_strategy("custom_demo", plugin: "custom_demo")
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # Same through ANSIBLE_STRATEGY_PLUGINS, the path the issue's repro
  # uses. Passed as a child env so no process-wide ENV is touched.
  it "accepts a strategy plugin from ANSIBLE_STRATEGY_PLUGINS" do
    code, lines, _ = run_strategy("custom_demo", plugin: "custom_demo", plugin_env: true)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # A RELATIVE ANSIBLE_STRATEGY_PLUGINS entry is resolved against the
  # directory ansible-playbook was invoked from, not the playbook's own
  # directory (issue #1460). This engine chdirs into the playbook dir at
  # startup, so a playbook in a subdirectory must still find the plugin
  # named relative to the invocation cwd, exactly as ansible does.
  it "resolves a relative ANSIBLE_STRATEGY_PLUGINS from the invocation directory" do
    code, lines, _ = run_strategy("custom_demo", plugin: "custom_demo", plugin_env: true,
      playbook_subdir: "sub", relative_plugin_env: true)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # Accepting the name is only half of it: the plugin's own `run()` never
  # executes here, so the run has to say so. Real prints whatever the
  # plugin itself does (issue #1456's retry_demo warns "retry_demo
  # strategy is active" and retries failed tasks), while a krikri run
  # that stayed silent is exactly what the issue reported.
  it "warns that a third-party strategy plugin is ignored" do
    warning = "[WARNING]: Strategy plugin 'custom_demo' cannot be executed by krikri-playbook and is ignored; the play runs with the linear strategy."

    code, _, output = run_strategy("custom_demo", plugin: "custom_demo")
    code.must_equal(0)
    output.scan(warning).size.must_equal(1)

    # ANSIBLE_STRATEGY resolves the same plugin and warns the same way.
    code, _, output = run_strategy(nil, plugin: "custom_demo", plugin_env: true,
      env: {"ANSIBLE_STRATEGY" => "custom_demo"})
    code.must_equal(0)
    output.scan(warning).size.must_equal(1)
  end

  # ANSIBLE_STRATEGY supplies the default strategy for a play that does
  # not set `strategy:` - ansible-core's DEFAULT_STRATEGY setting - so the
  # free interleaving has to show up with only the env var set.
  it "takes the default strategy from ANSIBLE_STRATEGY" do
    code, lines, _ = run_strategy(nil, env: {"ANSIBLE_STRATEGY" => "free"})
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(2)
    lines.must_equal([
      "TASK [slow on h1]", "changed:h2",
      "TASK [second]", "changed:h2",
      "TASK [slow on h1]", "changed:h1",
      "TASK [second]", "changed:h1",
    ])
  end

  # The play keyword wins over the setting, as in ansible: with
  # ANSIBLE_STRATEGY=free an explicit `strategy: linear` still keeps the
  # barrier (verified against ansible-core 2.21.6).
  it "lets the strategy keyword override ANSIBLE_STRATEGY" do
    code, lines, _ = run_strategy("linear", env: {"ANSIBLE_STRATEGY" => "free"})
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # The env var goes through the same plugin resolution as the keyword,
  # so a plugin name it carries is accepted (running as linear) rather
  # than refused.
  it "resolves a strategy plugin named by ANSIBLE_STRATEGY" do
    code, lines, _ = run_strategy(nil, plugin: "custom_demo", plugin_env: true,
      env: {"ANSIBLE_STRATEGY" => "custom_demo"})
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
  end

  # An invalid ANSIBLE_STRATEGY must stop the run with ansible's own
  # message instead of being silently dropped: real ansible raises
  # "Invalid play strategy specified: bogus" and exits 1.
  it "refuses an unknown ANSIBLE_STRATEGY" do
    code, _, output = run_strategy(nil, env: {"ANSIBLE_STRATEGY" => "bogus"})
    code.must_equal(1)
    output.must_include("Invalid play strategy specified: bogus")
  end

  # A failure's `[ERROR]:` block belongs under its task banner: real
  # prints the banner, the block, then the fatal line (live-verified vs
  # ansible-core 2.21.6). free/host_pinned buffers a host's whole
  # sequence - banner included - and flushes it later, so a block written
  # straight to stdout escaped ahead of the banner (issue #1472).
  it "prints a failure's error block under the task banner with host_pinned" do
    dir = File.tempname("strategy-error-block")
    begin
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "inv.ini"), "[g]\nh1 ansible_connection=local\n")
      File.write(File.join(dir, "pb.yml"), <<-YAML)
        - hosts: all
          gather_facts: false
          strategy: host_pinned
          tasks:
            - name: fails
              ansible.builtin.command: /bin/false
              ignore_errors: true
        YAML
      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
        output: output, error: output, chdir: dir, env: {"ANSIBLE_STRATEGY" => nil})
      status.exit_code.must_equal(0)
      text = output.to_s
      banner = text.index!("TASK [fails]")
      block = text.index!("[ERROR]: Task failed: Module failed: The command exited with a non-zero return code.")
      fatal = text.index!("fatal: [h1]")
      (banner < block).must_equal(true)
      (block < fatal).must_equal(true)
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # Under free/host_pinned ansible's default callback prints the task
  # banner lazily, on the task's first RESULT, so a retried task's
  # `FAILED - RETRYING` lines precede its banner (live-verified vs
  # ansible-core 2.21.6). linear still prints the banner up front, before
  # the retry lines (issue #1472).
  it "prints FAILED - RETRYING lines before the task banner with host_pinned" do
    dir = File.tempname("strategy-retry-banner")
    begin
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "inv.ini"), "[g]\nh1 ansible_connection=local\n")
      {"host_pinned" => false, "linear" => true}.each do |strategy, banner_first|
        File.write(File.join(dir, "pb.yml"), <<-YAML)
          - hosts: all
            gather_facts: false
            strategy: #{strategy}
            tasks:
              - name: retried
                ansible.builtin.command: /bin/false
                register: r
                retries: 2
                delay: 0
                until: r.rc == 0
                ignore_errors: true
          YAML
        output = IO::Memory.new
        status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
          output: output, error: output, chdir: dir, env: {"ANSIBLE_STRATEGY" => nil})
        status.exit_code.must_equal(0)
        text = output.to_s
        banner = text.index!("TASK [retried]")
        retry_line = text.index!("FAILED - RETRYING: [h1]: retried (1 retries left).")
        (banner < retry_line).must_equal(banner_first)
      end
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
