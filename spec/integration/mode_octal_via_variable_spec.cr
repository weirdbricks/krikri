require "../spec_helper"

# Runs the compiled binary against a real playbook (real directory
# creation + a real stat), since this bug is specifically about
# TaskExecutor#substitute_task_params, a private method not reachable
# from a unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "mode: piped through a variable that's itself an unquoted-octal YAML literal" do
  it "recovers the octal digits and stays idempotent, matching real ansible-playbook" do
    # Real bug found benchmarking geerlingguy.redis: its own "Ensure
    # Redis configuration dir exists." task writes
    # `mode: "{{ redis_conf_dir_mode }}"` where redis_conf_dir_mode:
    # 02770 is defined in vars/Debian.yml. Crystal's own YAML parser
    # (like real Ansible's) resolves the unquoted leading-zero literal
    # to the *decimal* Int64 1528 at vars-file parse time - a leading-
    # zero direct `mode: 0640` literal already gets its octal digits
    # recovered (see playbook_parser.cr's own comment on that fix), but
    # piping the same decimal-converted int through a variable and a
    # bare `{{ }}` template bypassed that recovery entirely:
    # #substitute_task_params just stringified the decimal Int64 as
    # "1528" verbatim. file.cr's own mode parser (`\A0?[0-7]{3,4}\z`)
    # rejects "1528" outright (an 8 isn't a valid octal digit), so it
    # fell through to the symbolic-mode branch and shelled out to
    # `chmod 1528 <path>` - an invalid mode chmod silently ignores
    # (rescued), leaving the directory at whatever Dir.mkdir_p's own
    # default happened to produce, and reporting "changed" on every
    # subsequent run since the (never-applied) target mode could never
    # match the real one.
    dir = File.tempname("mode-octal-via-variable")
    playbook = File.tempname("mode-octal-via-variable", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          my_mode: 02770
        tasks:
          - name: make dir
            ansible.builtin.file:
              path: #{dir}
              state: directory
              mode: "{{ my_mode }}"
      YAML

    output1 = IO::Memory.new
    status1 = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output1, error: output1)
    status1.success?.should be_true

    stat_output = IO::Memory.new
    Process.run("stat", ["-c", "%a", dir], output: stat_output)
    stat_output.to_s.strip.should eq("2770")

    # Idempotency: a second run against the now-correctly-set directory
    # must report no change, not "changed" forever.
    output2 = IO::Memory.new
    status2 = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output2, error: output2)
    status2.success?.should be_true
    output2.to_s.should_not contain("changed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    Dir.delete(dir) if dir && Dir.exists?(dir)
  end

  it "does not re-reformat an int mode that was already decimal-coerced from an octal-style STRING" do
    # Real bug found live-verifying CRINJA.md step 5 against dev-sec
    # os_hardening on a real host: its own dynamic `set_fact: "{{
    # item.key }}": "{{ item.value }}"` (see plugins/set_fact.cr's own
    # `coerce`) decimal-parses an already-octal-style STRING like "1777"
    # into the int 1777 directly - no YAML octal-literal parsing
    # involved at all, unlike the case above. Reformatting that int via
    # `to_s(8)` (as if it were a YAML-octal-derived decimal, like the
    # 1528 case above) treats 1777's decimal VALUE as needing
    # re-expression in octal, producing "3361" instead of the original
    # "1777" - a real corrupted chmod on `/dev/shm`/`/tmp`/`/var/tmp`
    # directories. Since "1777" already looks like a valid octal mode on
    # its own (all digits 0-7, 3-4 of them), it must be used as-is, not
    # reformatted.
    #
    # NOTE: originally this spec reproduced os_hardening's exact shape
    # via `set_fact: "{{ item.key }}": "{{ item.value }}"` + `loop: "{{
    # os_vars | dict2items }}"`, but `dict2items` is itself still
    # unimplemented in crystal-ansible's FilterEngine (it passes the dict
    # through unchanged), so that loop never actually set `my_mode` and
    # the spec silently tested nothing. Reproduce the decimal-coercion
    # directly instead: a plain `set_fact: my_mode: "1777"` routes the
    # string through set_fact's own `coerce`, which decimal-parses it to
    # the int 1777 - the exact value the fix must not re-reformat.
    dir = File.tempname("mode-decimal-coerced-octal")
    playbook = File.tempname("mode-decimal-coerced-octal", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: set_fact decimal-coerces the octal-style string
            ansible.builtin.set_fact:
              my_mode: "1777"
          - name: make dir
            ansible.builtin.file:
              path: #{dir}
              state: directory
              mode: "{{ my_mode }}"
      YAML

    output1 = IO::Memory.new
    status1 = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output1, error: output1)
    status1.success?.should be_true

    stat_output = IO::Memory.new
    Process.run("stat", ["-c", "%a", dir], output: stat_output)
    stat_output.to_s.strip.should eq("1777")

    # Idempotency: the already-correctly-set directory must not be
    # re-formatted/re-chmod'd on a second run.
    output2 = IO::Memory.new
    status2 = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output2, error: output2)
    status2.success?.should be_true
    output2.to_s.should_not contain("changed=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    Dir.delete(dir) if dir && Dir.exists?(dir)
  end
end
