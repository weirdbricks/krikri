require "../minitest_helper"

# Real's free/host_pinned strategy loop refuses a task whose action plugin
# declares BYPASS_HOST_LOOP (pause, add_host) as it DEQUEUES it: such a
# task would run once per host in the inventory instead of through the
# per-host loop. The refusal is a strategy-level error, so it prints the
# [ERROR] + Origin block on stderr and ends the run at rc=1 - before the
# task's banner, its when:/ignore_errors:/check-mode handling, and before
# any PLAY RECAP (live-verified vs ansible-core 2.21.6, issue #1810).
private BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

private def run_free_bypass(yaml : String, hosts : Array(String) = ["h1"], args : Array(String) = [] of String) : {Int32, String, String}
  dir = PluginSpecHelper.tmp_path("free-bypass.yml")
  Dir.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, String.build do |io|
    io << "[g]\n"
    hosts.each { |host| io << "#{host} ansible_connection=local\n" }
  end)
  playbook = File.join(dir, "pb.yml")
  File.write(playbook, yaml)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv] + args + [playbook],
    output: stdout, error: stderr, chdir: dir)
  {status.exit_code, stdout.to_s, stderr.to_s}
end

private FREE_BYPASS_MESSAGE = "The 'ansible.builtin.pause' module bypasses the host loop, " \
                              "which is currently not supported in the free strategy and would " \
                              "instead execute for every host in the inventory list."

describe "free strategy bypass host loop" do
  it "aborts a pause task before its banner" do
    code, stdout, stderr = run_free_bypass(<<-YAML, args: ["--check"])
      ---
      - name: free pause
        hosts: g
        gather_facts: false
        strategy: free
        tasks:
          - name: Pause task
            ansible.builtin.pause:
              echo: "false"
              seconds: "1"
            ignore_errors: true
      YAML

    code.must_equal(1)
    stderr.must_include("[ERROR]: #{FREE_BYPASS_MESSAGE}")
    stderr.must_include("Origin: ")
    stderr.must_include("^ column 7")
    stdout.must_include("PLAY [free pause]")
    stdout.wont_include("TASK [Pause task]")
    stdout.wont_include("Pausing for")
    stdout.wont_include("PLAY RECAP")
  end

  it "aborts a pause task whose when: would skip it" do
    code, stdout, stderr = run_free_bypass(<<-YAML)
      ---
      - name: free pause skipped
        hosts: g
        gather_facts: false
        strategy: host_pinned
        tasks:
          - name: Pause task
            ansible.builtin.pause:
              seconds: "1"
            when: false
      YAML

    code.must_equal(1)
    stderr.must_include("[ERROR]: #{FREE_BYPASS_MESSAGE}")
    stdout.wont_include("TASK [Pause task]")
    stdout.wont_include("skipping:")
    stdout.wont_include("PLAY RECAP")
  end

  it "aborts an add_host task" do
    code, stdout, stderr = run_free_bypass(<<-YAML)
      ---
      - name: free add_host
        hosts: g
        gather_facts: false
        strategy: free
        tasks:
          - name: Add host
            ansible.builtin.add_host:
              name: extra
      YAML

    code.must_equal(1)
    stderr.must_include("The 'ansible.builtin.add_host' module bypasses the host loop")
    stdout.wont_include("TASK [Add host]")
    stdout.wont_include("PLAY RECAP")
  end

  it "aborts a notified pause handler before its RUNNING HANDLER banner" do
    code, stdout, stderr = run_free_bypass(<<-YAML)
      ---
      - name: free pause handler
        hosts: g
        gather_facts: false
        strategy: free
        tasks:
          - name: notifier
            ansible.builtin.command:
              cmd: /bin/true
            changed_when: true
            notify: Pause handler
        handlers:
          - name: Pause handler
            ansible.builtin.pause:
              seconds: "1"
      YAML

    code.must_equal(1)
    stderr.must_include("[ERROR]: #{FREE_BYPASS_MESSAGE}")
    stdout.must_include("changed: [h1]")
    stdout.wont_include("RUNNING HANDLER")
    stdout.wont_include("PLAY RECAP")
  end

  it "aborts once when several hosts reach the task" do
    code, stdout, stderr = run_free_bypass(<<-YAML, hosts: ["h1", "h2"])
      ---
      - name: free pause two hosts
        hosts: g
        gather_facts: false
        strategy: free
        tasks:
          - name: Pause task
            ansible.builtin.pause:
              seconds: "1"
      YAML

    code.must_equal(1)
    stderr.scan(/\[ERROR\]: #{Regex.escape(FREE_BYPASS_MESSAGE)}/).size.must_equal(1)
    stdout.wont_include("Pausing for")
    stdout.wont_include("PLAY RECAP")
  end

  it "still runs a pause task under the linear strategy" do
    code, stdout, _stderr = run_free_bypass(<<-YAML)
      ---
      - name: linear pause
        hosts: g
        gather_facts: false
        tasks:
          - name: Pause task
            ansible.builtin.pause:
              seconds: "1"
      YAML

    code.must_equal(0)
    stdout.must_include("TASK [Pause task]")
    stdout.must_include("Pausing for 1 seconds")
    stdout.must_include("PLAY RECAP")
  end
end
