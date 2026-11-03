require "../minitest_helper"

# Runs the compiled binary against a real playbook: the legacy k=v merge
# deprecation is parse-time stderr output, only observable end-to-end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real 2.19.11 (mod_args.py's _normalize_new_style_args, issue #792 -
# stancel.git_deploy_setup) warns at task load when a free-form STRING
# module value beside an `args:` keyword parses into k=v keys.
describe "legacy k=v merge deprecation" do
  it "warns at load for shell chdir= beside args with the value-start Origin" do
    playbook = File.tempname("legacy-kv-merge", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: Create git repo for new site
            shell: echo hi chdir=/tmp
            args:
              creates: /tmp/marker
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    err.must_include("[DEPRECATION WARNING]: Merging legacy k=v args ('chdir') into task args. This feature will be removed from ansible-core version 2.23.")
    # The Origin is the module key's VALUE node start: "      shell: " is
    # 13 characters, so the value's first character sits at column 14 -
    # real 2.19.11 reports the same position for the issue's role task.
    err.must_include("Origin: #{File.expand_path(playbook)}:6:14")
    err.must_include("Include all task args in the task `args` mapping.")
    # The task itself still runs normally.
    stdout.to_s.must_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real only excludes the `args:` keyword's ABSENCE: no args:, no
  # warning, even though the string still parses into k=v keys.
  it "stays silent without an args keyword" do
    playbook = File.tempname("legacy-kv-merge-no-args", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: plain shell
            shell: echo hi chdir=/tmp
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr.to_s.wont_include("Merging legacy k=v args")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # parse_kv's check_raw=True (the free-form command family) only lets
  # the eight command specials become keys: a token like VAR=1 stays
  # command text and is never named, while every other module's k=v
  # tokens all are (sorted, repr-quoted, comma-joined).
  it "names only command specials for shell and every key for other modules" do
    playbook = File.tempname("legacy-kv-merge-keyset", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: shell non-special kv
            shell: echo VAR=1 chdir=/tmp
            args:
              creates: /tmp/marker
          - name: file module kv
            file: path=/tmp state=directory mode=0755
            args:
              recurse: yes
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.must_include("[DEPRECATION WARNING]: Merging legacy k=v args ('chdir') into task args.")
    err.must_include("[DEPRECATION WARNING]: Merging legacy k=v args ('mode', 'path', 'state') into task args.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Display dedups by full text (header + Origin + help): a looped task
  # warns once despite running per item, while two tasks whose texts
  # differ only by Origin each warn - the issue's own shape (its two
  # tasks at lines 17 and 62 both display).
  it "dedups a looped task but keeps both same-text tasks' Origins" do
    playbook = File.tempname("legacy-kv-merge-dedup", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: looped shell
            shell: echo hi chdir=/tmp
            args:
              creates: /tmp/marker
            loop:
              - a
              - b
          - name: second same-text shell
            shell: echo hi chdir=/tmp
            args:
              creates: /tmp/marker
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
    err = stderr.to_s

    err.scan(/Merging legacy k=v args/).size.must_equal(2)
    err.must_include("Origin: #{File.expand_path(playbook)}:6:14")
    err.must_include("Origin: #{File.expand_path(playbook)}:13:14")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real's old-style `action:`/`local_action:` directives parse through
  # _normalize_old_style_args, which never emits this deprecation - even
  # with a k=v-bearing string beside an args: keyword.
  it "stays silent for old-style action directives" do
    playbook = File.tempname("legacy-kv-merge-action", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: string action
            action: shell echo hi chdir=/tmp
            args:
              creates: /tmp/marker
          - name: local action
            local_action: shell echo hi chdir=/tmp
            args:
              creates: /tmp/marker
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr.to_s.wont_include("Merging legacy k=v args")
    stdout.to_s.must_include("PLAY RECAP")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
