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

private def run_strategy(strategy : String?, plugin : String? = nil, plugin_env : Bool = false, # ameba:disable Metrics/CyclomaticComplexity
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
  # NAME and then refuses the play, since it cannot execute Python
  # strategy code (issue #1657).
  plugin_dir = plugin_env ? File.join(dir, "plugin_env") : File.join(dir, "strategy_plugins")
  if plugin_name = plugin
    Dir.mkdir_p(plugin_dir)
    File.write(File.join(plugin_dir, "#{plugin_name}.py"), "")
  end
  line = strategy ? "  strategy: #{strategy}\n" : ""
  # Under free/host_pinned the assertions pin h2 finishing BOTH tasks
  # before h1 finishes its first. A fixed `sleep 1` on h1 made that a race
  # the suite lost under load (h2's two tasks took longer than 1s), so h1
  # instead waits for h2's second task to have run (bounded at 30s). Under
  # linear the barrier would keep that marker from ever appearing, so the
  # plain sleep stays there - linear's order never depended on timing.
  free_like = (strategy || env["ANSIBLE_STRATEGY"]?).in?("free", "host_pinned")
  h1_wait = if free_like
              "i=0; while [ ! -f #{dir}/h2-second ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done"
            else
              "sleep 1"
            end
  second_cmd = free_like ? %(sh -c "touch #{dir}/{{ inventory_hostname }}-second; echo B") : "echo B"
  playbook_rel = playbook_subdir ? File.join(playbook_subdir, "pb.yml") : "pb.yml"
  Dir.mkdir_p(File.dirname(File.join(dir, playbook_rel)))
  File.write(File.join(dir, playbook_rel), <<-YAML)
    - hosts: all
      gather_facts: false
    #{line.rstrip}
      tasks:
        - name: slow on h1
          ansible.builtin.command: sh -c "test '{{ inventory_hostname }}' = h1 && { #{h1_wait}; }; echo A"
        - name: second
          ansible.builtin.command: #{second_cmd}
    YAML

  stdout_io = IO::Memory.new
  # Pin ANSIBLE_STRATEGY as unset unless a test supplies it, so a
  # developer's own exported value cannot change these expectations.
  # The retry fallback is the opt-in for a third-party strategy plugin,
  # so its settings are pinned the same way.
  child_env = {
    "ANSIBLE_STRATEGY"            => nil,
    "KRIKRI_STRATEGY_RETRIES"     => nil,
    "KRIKRI_STRATEGY_RETRY_DELAY" => nil,
  }.merge(env)
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

  # A strategy plugin beside the playbook is found by Ansible's loader
  # (`strategy_plugins/` is searched first) and LOADED AND RUN by real.
  # This engine cannot execute that Python control-plane code, so the
  # play is refused at startup instead of being run as linear with
  # results the plugin never produced (issue #1657).
  it "refuses a playbook-local strategy plugin at startup" do
    code, _, output = run_strategy("custom_demo", plugin: "custom_demo")
    code.must_equal(1)
    output.must_include("Strategy plugin 'custom_demo'")
    output.must_include("KRIKRI_STRATEGY_RETRIES")
    output.wont_include("PLAY [")
  end

  # Same through ANSIBLE_STRATEGY_PLUGINS, the path the issue's repro
  # uses. Passed as a child env so no process-wide ENV is touched.
  it "refuses a strategy plugin found via ANSIBLE_STRATEGY_PLUGINS" do
    code, _, output = run_strategy("custom_demo", plugin: "custom_demo", plugin_env: true)
    code.must_equal(1)
    output.must_include("Strategy plugin 'custom_demo'")
    output.wont_include("PLAY [")
  end

  # A RELATIVE ANSIBLE_STRATEGY_PLUGINS entry is resolved against the
  # directory ansible-playbook was invoked from, not the playbook's own
  # directory (issue #1460). This engine chdirs into the playbook dir at
  # startup, so a playbook in a subdirectory must still find the plugin
  # named relative to the invocation cwd, exactly as ansible does.
  it "resolves a relative ANSIBLE_STRATEGY_PLUGINS from the invocation directory" do
    code, _, output = run_strategy("custom_demo", plugin: "custom_demo", plugin_env: true,
      playbook_subdir: "sub", relative_plugin_env: true)
    code.must_equal(1)
    # Resolving the plugin is what produces the refusal; a name no
    # loader path carries still gets ansible's "Invalid play strategy
    # specified" instead.
    output.must_include("Strategy plugin 'custom_demo' (")
    output.wont_include("Invalid play strategy specified")
  end

  # The retry fallback's env setting is the explicit opt-in to the
  # degraded linear run (issue #1542). An opted-in run prints exactly
  # the deprecation pair real prints for a non-builtin strategy - no
  # line of krikri's own - which is what keeps the run's transcript
  # comparable to real's (issue #1657's corpus case pins it).
  it "runs an opted-in third-party strategy plugin as linear, like real's warnings" do
    deprecation = "[DEPRECATION WARNING]: Use of strategy plugins not included in ansible.builtin are deprecated and do not carry any backwards compatibility guarantees."
    opt_in = {"KRIKRI_STRATEGY_RETRIES" => "1"} of String => String?

    code, lines, output = run_strategy("custom_demo", plugin: "custom_demo", env: opt_in)
    code.must_equal(0)
    lines.count(&.starts_with?("TASK [slow")).must_equal(1)
    output.must_include(deprecation)
    output.wont_include("Strategy plugin 'custom_demo' cannot be executed")

    # ANSIBLE_STRATEGY resolves the same plugin and behaves the same way.
    code, _, output = run_strategy(nil, plugin: "custom_demo", plugin_env: true,
      env: opt_in.merge({"ANSIBLE_STRATEGY" => "custom_demo"}))
    code.must_equal(0)
    output.must_include(deprecation)
    output.wont_include("Strategy plugin 'custom_demo' cannot be executed")
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
  # so the plugin it carries is refused the same way at startup.
  it "refuses a strategy plugin named by ANSIBLE_STRATEGY" do
    code, _, output = run_strategy(nil, plugin: "custom_demo", plugin_env: true,
      env: {"ANSIBLE_STRATEGY" => "custom_demo"})
    code.must_equal(1)
    output.must_include("Strategy plugin 'custom_demo'")
    output.wont_include("PLAY [")
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

  # Under free/host_pinned the default callback prints a task's banner
  # lazily, on its first RESULT line - so a meta: task, which produces no
  # result at all, shows no banner in real. The one exception is a meta:
  # whose own when: skips it: that DOES have a `skipping:` result, and
  # real prints the banner above it (live-verified against ansible-core
  # 2.21.6, issue #1500).
  it "prints no task banner for a meta task without a result with host_pinned" do
    dir = File.tempname("strategy-meta-banner")
    begin
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "inv.ini"), "[g]\nh1 ansible_connection=local\n")
      File.write(File.join(dir, "pb.yml"), <<-YAML)
        - hosts: all
          gather_facts: false
          strategy: host_pinned
          tasks:
            - name: noop task
              ansible.builtin.meta: noop
            - name: flush handlers
              ansible.builtin.meta: flush_handlers
            - name: flush with a false when
              ansible.builtin.meta: flush_handlers
              when: false
            - name: after
              ansible.builtin.debug:
                msg: after
        YAML
      output = IO::Memory.new
      status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
        output: output, error: output, chdir: dir, env: {"ANSIBLE_STRATEGY" => nil})
      status.exit_code.must_equal(0)
      text = output.to_s
      text.wont_include("TASK [noop task]")
      text.wont_include("TASK [flush handlers]")
      banner = text.index!("TASK [flush with a false when]")
      skipped = text.index!("skipping: [h1]")
      banner.wont_be_nil
      skipped.wont_be_nil
      (banner.as(Int32) < skipped.as(Int32)).must_equal(true)
      text.must_include("TASK [after]")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # A strategy plugin that wraps linear and retries failed tasks is the
  # common case (issue #1542): its Python cannot run here, so a linear
  # run without a stand-in fails the host on the first attempt. The play
  # is therefore refused at startup unless the operator opts into the
  # degraded linear run with the krikri-side settings, which supply the
  # plugin's attempt count and gap for a task that wrote neither
  # `retries:` nor `until:` - ansible's task_executor then retries on
  # `not utr.failed` - so that run keeps the same pass/fail outcome and
  # the same FAILED - RETRYING lines (issue #1657).
  it "refuses an ignored strategy plugin unless the retry fallback is opted in" do
    dir = File.tempname("strategy-retry-fallback")
    counter = File.join(dir, "count")
    begin
      Dir.mkdir_p(File.join(dir, "strategy_plugins"))
      File.write(File.join(dir, "strategy_plugins", "retry_demo.py"), "")
      File.write(File.join(dir, "inv.ini"), "[g]\nlocalhost ansible_connection=local\n")
      File.write(File.join(dir, "pb.yml"), <<-YAML)
        - hosts: all
          gather_facts: false
          strategy: retry_demo
          tasks:
            - name: flaky
              shell: |
                f=#{counter}; n=$(cat $f 2>/dev/null || echo 0); n=$((n+1)); echo $n > $f
                [ $n -ge 3 ]
              changed_when: false
        YAML

      run_it = ->(env : Hash(String, String?)) do
        output = IO::Memory.new
        status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
          output: output, error: output, chdir: dir,
          env: {
            "ANSIBLE_STRATEGY"            => nil,
            "ANSIBLE_STRATEGY_PLUGINS"    => nil,
            "KRIKRI_STRATEGY_RETRIES"     => nil,
            "KRIKRI_STRATEGY_RETRY_DELAY" => nil,
          }.merge(env))
        {status.exit_code, output.to_s}
      end

      # Without the opt-in nothing runs: exactly the failure mode issue
      # #1657 reported, where a first-attempt linear failure (failed=1)
      # replaced the plugin's passing third attempt.
      File.delete(counter) if File.exists?(counter)
      code, output = run_it.call({} of String => String?)
      code.must_equal(1)
      output.must_include("Strategy plugin 'retry_demo'")
      File.exists?(counter).must_equal(false)

      File.delete(counter) if File.exists?(counter)
      fallback_env = {"KRIKRI_STRATEGY_RETRIES" => "2", "KRIKRI_STRATEGY_RETRY_DELAY" => "0"} of String => String?
      code, output = run_it.call(fallback_env)
      code.must_equal(0)
      File.read(counter).strip.must_equal("3")
      output.scan("FAILED - RETRYING: [localhost]: flaky (1 retries left).").size.must_equal(1)
      output.scan("FAILED - RETRYING: [localhost]: flaky (0 retries left).").size.must_equal(1)
      output.must_include("ok: [localhost]")
      output.must_include("ok=1")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # The issue's own repro: a plugin whose __init__ writes a marker file.
  # Real imports and instantiates it, so the marker appears;
  # krikri-playbook cannot execute it, and must not let the play run as
  # if it had - refusing at startup leaves no marker and no task output,
  # whether or not the linear fallback was opted into.
  it "never executes a third-party strategy plugin's code" do
    dir = File.tempname("strategy-marker")
    marker = File.join(dir, "marker")
    begin
      Dir.mkdir_p(File.join(dir, "strategy_plugins"))
      File.write(File.join(dir, "strategy_plugins", "marker_strategy.py"), <<-PY)
        from ansible.plugins.strategy.linear import StrategyModule as Linear

        DOCUMENTATION = "name: marker_strategy\\nshort_description: marker\\n"


        class StrategyModule(Linear):
            def __init__(self, tqm):
                open("#{marker}", "w").write("x")
                super().__init__(tqm)
        PY
      File.write(File.join(dir, "inv.ini"), "[g]\nlocalhost ansible_connection=local\n")
      File.write(File.join(dir, "pb.yml"), <<-YAML)
        - hosts: all
          gather_facts: false
          strategy: marker_strategy
          tasks:
            - name: ping
              ansible.builtin.ping:
        YAML

      {nil, "1"}.each do |fallback|
        File.delete(marker) if File.exists?(marker)
        output = IO::Memory.new
        status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
          output: output, error: output, chdir: dir,
          env: {
            "ANSIBLE_STRATEGY"            => nil,
            "ANSIBLE_STRATEGY_PLUGINS"    => nil,
            "KRIKRI_STRATEGY_RETRIES"     => fallback,
            "KRIKRI_STRATEGY_RETRY_DELAY" => nil,
          })
        # With the opt-in the play runs linearly, without it the run
        # stops before any task - either way the plugin's own code never
        # ran.
        status.exit_code.must_equal(fallback ? 0 : 1)
        File.exists?(marker).must_equal(false)
        output.to_s.wont_include("TASK [ping]") unless fallback
      end
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
