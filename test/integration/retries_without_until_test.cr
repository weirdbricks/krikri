require "file_utils"
require "../minitest_helper"

# Ansible's attempt loop engages on `retries:` alone: with no `until:`
# its condition is literally `self._task.until or [not utr.failed]`
# (task_executor.py's _execute), so `retries: 2` + `delay: 0` runs a
# failing task three times and succeeds as soon as one attempt returns a
# healthy result. krikri only entered the loop when `until:` was
# present, so a `retries:`-only task ran once - the same shape
# StrategyRetryFallback leans on for an ignored third-party strategy
# plugin (issue #1542), and checked live against ansible-core 2.21.6 for
# the plain task, the loop item and the handler shapes below.
private RETRIES_NO_UNTIL_ROOT = File.expand_path("../..", __DIR__)
private RETRIES_NO_UNTIL_BIN  = File.join(RETRIES_NO_UNTIL_ROOT, "bin", "krikri-playbook")

private def run_retries_without_until(yaml : String, env : Hash(String, String?) = {} of String => String?) : {Int32, String}
  dir = File.tempname("retries-no-until")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "[g]\nlocalhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), yaml)
  output = IO::Memory.new
  status = Process.run(RETRIES_NO_UNTIL_BIN, ["-i", "inv.ini", "pb.yml"],
    output: output, error: output, chdir: dir,
    env: {"ANSIBLE_STRATEGY" => nil}.merge(env))
  {status.exit_code, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "retries: without until:" do
  it "retries a failing task until an attempt succeeds" do
    counter = File.tempname("retries-no-until-count")
    File.delete(counter) if File.exists?(counter)

    begin
      code, output = run_retries_without_until(<<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: flaky
              shell: |
                f=#{counter}; n=$(cat $f 2>/dev/null || echo 0); n=$((n+1)); echo $n > $f
                [ $n -ge 3 ]
              changed_when: false
              retries: 2
              delay: 0
              register: r
            - name: show
              ansible.builtin.debug:
                msg: "attempts={{ r.attempts }} failed={{ r.failed }}"
        YAML

      code.must_equal(0)
      File.read(counter).strip.must_equal("3")
      output.scan("FAILED - RETRYING: [localhost]: flaky (1 retries left).").size.must_equal(1)
      output.scan("FAILED - RETRYING: [localhost]: flaky (0 retries left).").size.must_equal(1)
      output.must_include("ok: [localhost]")
      # The successful attempt's registered result keeps its attempt
      # number, exactly as task_executor's `utr.attempts = attempt` does.
      output.must_include(%("msg": "attempts=3 failed=False"))
    ensure
      File.delete(counter) if counter && File.exists?(counter)
    end
  end

  it "exhausts the attempts and fails with the attempts key" do
    code, output = run_retries_without_until(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: always fails
            ansible.builtin.command: /bin/false
            retries: 2
            delay: 0
            changed_when: false
      YAML

    code.must_equal(2)
    output.scan("FAILED - RETRYING: [localhost]: always fails").size.must_equal(2)
    # Every attempt ran: the 1 + retries budget. The exhausted result
    # carries the retries value, not the attempt count (real's
    # `utr.attempts = retries - 1`), and the ordinary failure pipeline
    # reports it.
    output.must_include(%("attempts": 2))
    output.must_include("failed=1")
  end

  it "retries each loop item independently" do
    dir = File.tempname("retries-no-until-loop")
    Dir.mkdir_p(dir)
    begin
      code, output = run_retries_without_until(<<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: loop retries
              shell: |
                f=#{dir}/count-{{ item }}; n=$(cat $f 2>/dev/null || echo 0); n=$((n+1)); echo $n > $f
                [ $n -ge 2 ]
              changed_when: false
              loop:
                - a
                - b
              retries: 1
              delay: 0
        YAML

      code.must_equal(0)
      File.read(File.join(dir, "count-a")).strip.must_equal("2")
      File.read(File.join(dir, "count-b")).strip.must_equal("2")
      # One retry line per item, immediately before that item's result.
      output.scan("FAILED - RETRYING: [localhost]: loop retries (0 retries left).").size.must_equal(2)
      output.must_include("ok: [localhost] => (item=a)")
      output.must_include("ok: [localhost] => (item=b)")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "retries a handler notified by a changed task" do
    counter = File.tempname("retries-no-until-handler-count")
    File.delete(counter) if File.exists?(counter)

    begin
      code, output = run_retries_without_until(<<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: notify
              ansible.builtin.command: /bin/true
              changed_when: true
              notify: flaky handler
          handlers:
            - name: flaky handler
              shell: |
                f=#{counter}; n=$(cat $f 2>/dev/null || echo 0); n=$((n+1)); echo $n > $f
                [ $n -ge 2 ]
              changed_when: false
              retries: 1
              delay: 0
        YAML

      code.must_equal(0)
      File.read(counter).strip.must_equal("2")
      output.must_include("RUNNING HANDLER [flaky handler]")
      output.scan("FAILED - RETRYING: [localhost]: flaky handler (0 retries left).").size.must_equal(1)
    ensure
      File.delete(counter) if counter && File.exists?(counter)
    end
  end
end
