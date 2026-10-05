require "../minitest_helper"

# -e / --extra-vars, Ansible's highest-precedence variable scope.
# Every expectation here was captured from a ansible-core 2.19.4 run
# of the same playbook, not derived.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    vars:
      myvar: FROM_PLAY_VARS
      num: 1
    tasks:
      - name: show
        ansible.builtin.debug:
          msg: "myvar={{ myvar }} num={{ num }} type={{ num | type_debug }}"
      - name: setfact
        ansible.builtin.set_fact:
          myvar: FROM_SET_FACT
      - name: show2
        ansible.builtin.debug:
          msg: "after_set_fact myvar={{ myvar }}"
  YAML

private def run_with(args : Array(String), yaml : String = PLAYBOOK)
  playbook = File.tempname("extra-vars", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: stdout_io, error: stdout_io)
  {status, stdout_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "--extra-vars" do
  it "leaves play vars alone when not passed" do
    _, output = run_with([] of String)
    output.must_include("myvar=FROM_PLAY_VARS")
  end

  it "overrides a play var with key=value" do
    _, output = run_with(["-e", "myvar=FROM_CLI"])
    output.must_include("myvar=FROM_CLI")
  end

  # The non-obvious one: a later set_fact can NOT override an extra-var.
  it "outranks a set_fact executed later in the same play" do
    _, output = run_with(["-e", "myvar=FROM_CLI"])
    output.must_include("after_set_fact myvar=FROM_CLI")
    output.wont_include("after_set_fact myvar=FROM_SET_FACT")
  end

  # key=value always yields a STRING - `-e num=5` is "5", not 5.
  it "gives key=value a string value, not a parsed number" do
    _, output = run_with(["-e", "num=5"])
    output.must_include("num=5 type=str")
  end

  # ...whereas the JSON form preserves real types.
  it "preserves real types from the JSON form" do
    _, output = run_with(["-e", %({"myvar":"FROM_JSON","num":7})])
    output.must_include("myvar=FROM_JSON")
    output.must_include("num=7 type=int")
  end

  it "accepts several whitespace-separated pairs in one -e" do
    _, output = run_with(["-e", "k1=v1 myvar=SPACED"])
    output.must_include("myvar=SPACED")
  end

  it "lets a later -e win over an earlier one" do
    _, output = run_with(["-e", "myvar=ONE", "-e", "myvar=TWO"])
    output.must_include("myvar=TWO")
  end

  it "loads a YAML file with @" do
    file = File.tempname("extra-vars-file", ".yml")
    File.write(file, "myvar: FROM_FILE\n")
    begin
      _, output = run_with(["-e", "@#{file}"])
      output.must_include("myvar=FROM_FILE")
    ensure
      File.delete(file) if File.exists?(file)
    end
  end

  it "loads a JSON file with @" do
    file = File.tempname("extra-vars-file", ".json")
    File.write(file, %({"myvar":"FROM_JSON_FILE"}))
    begin
      _, output = run_with(["-e", "@#{file}"])
      output.must_include("myvar=FROM_JSON_FILE")
    ensure
      File.delete(file) if File.exists?(file)
    end
  end

  it "reports a missing @file instead of crashing" do
    status, output = run_with(["-e", "@definitely-missing-vars-xyz.yml"])
    status.exit_code.must_equal(1)
    output.must_include("extra-vars file not found")
    output.wont_include("Unhandled exception")
  end

  it "outranks task-level vars, and can open a when: gate" do
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          gate: "no"
        tasks:
          - name: task vars
            ansible.builtin.debug:
              msg: "tv={{ tv }}"
            vars:
              tv: FROM_TASK_VARS
          - name: gated
            ansible.builtin.debug:
              msg: "GATE_OPEN"
            when: gate == "yes"
      YAML

    _, output = run_with(["-e", "tv=FROM_CLI"], yaml)
    output.must_include("tv=FROM_CLI")

    _, gated = run_with(["-e", "gate=yes"], yaml)
    gated.must_include("GATE_OPEN")
  end

  it "can supply a loop source" do
    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop: "{{ mylist | default([]) }}"
      YAML

    _, output = run_with(["-e", %({"mylist":["x","y"]})], yaml)
    output.must_include("item=x")
    output.must_include("item=y")
  end
end
