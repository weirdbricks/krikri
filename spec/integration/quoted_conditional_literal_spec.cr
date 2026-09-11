require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in
# ConditionalEvaluator's operator splitting, which needs a real
# changed_when:/failed_when: evaluation against a registered command
# result to exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a changed_when:/failed_when: whose whole value is one quoted string" do
  it "evaluates a fully-quoted changed_when as a Jinja string constant, not an expression to split" do
    # Real bug found benchmarking mrlesmithjr.mariadb_galera_cluster
    # (Atlantic round 310053): its "Check mariadb_version on target
    # system" task is
    #   ansible.builtin.command: "mariadb -V"
    #   register: mariadb_version_check
    #   failed_when: '"mariadb" not in mariadb_version_check.stdout
    #     and mariadb_version_check.rc == 0'
    #   changed_when: not 'mariadb_version_check.rc == 0'
    # On a host without the mariadb binary, real ansible-playbook
    # (core 2.19.4, verified live) ends the task ok (rc=2 ENOENT result,
    # failed_when false, changed_when's quoted string a truthy constant
    # so `not` -> changed=false); krikri failed the task with
    # "'mariadb_version_check.rc' is undefined" - the `==` split ran
    # INSIDE the quotes, producing the unbalanced-quote operand
    # "'mariadb_version_check.rc", which no variable lookup can ever
    # resolve. The quoted literal is now recognized as a constant
    # (truthy iff non-empty interior) before any operator splitting.
    src_dir = File.tempname("quoted-conditional-literal")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: check missing binary
            ansible.builtin.command: "mariadb -V"
            check_mode: false
            register: mariadb_version_check
            failed_when: '"mariadb" not in mariadb_version_check.stdout and mariadb_version_check.rc == 0'
            changed_when: not 'mariadb_version_check.rc == 0'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("ok=1")
    output.to_s.should_not contain("is undefined")
    output.to_s.should_not contain("fatal:")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still splits compound conditions that merely start and end with quotes" do
    # Guard for the narrow literal-recognition rule: `'a' == 'a'` starts
    # and ends with quotes but is a real comparison - it must keep
    # evaluating as one (true, here), not short-circuit to whole-string
    # truthiness.
    playbook = File.tempname("quoted-conditional-compound")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          myvar: a
        tasks:
          - name: runs
            debug:
              msg: RAN
            when: "'a' == myvar and 'x' != 'y'"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("RAN")
  ensure
    File.delete(playbook) if playbook
  end
end
