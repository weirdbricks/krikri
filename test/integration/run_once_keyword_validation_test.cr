require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")
private MULTI_HOST   = File.join(__DIR__, "..", "fixtures", "inventory-three-local-hosts.ini")

# Issue #1444: ansible post-validates the run_once: keyword with its strict
# boolean() when the task runs, so a value it cannot convert fails that task
# with "Error processing keyword 'run_once'" instead of running it. The
# keyword is inherited from the play, so a play-level value fails the play's
# first task that is not skipped, with the chain's lower links Origin'd at
# the play's own value token.
describe "run_once: keyword post-validation" do
  it "fails the first task on an unconvertible play-level run_once: value" do
    playbook = File.tempname("run-once-play-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        run_once: kpg-maybe
        tasks:
          - name: Invalid play run_once keyword
            ansible.builtin.debug:
              msg: INVALID-RUN-ONCE-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    # The failing task's own Origin, then the play's value token for both
    # lower chain links.
    output_text.must_include("Origin: #{File.expand_path(playbook)}:6:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:4:13")
    output_text.must_match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a task with its own unconvertible run_once: value" do
    playbook = File.tempname("run-once-task-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Invalid task run_once keyword
            ansible.builtin.debug:
              msg: INVALID-RUN-ONCE-RAN
            run_once: kpg-maybe
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'run_once': The value 'kpg-maybe' could not be converted to 'bool'.").must_equal(true, output_text)
    output_text.wont_include("ok: [localhost]")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:5:7")
    output_text.must_include("Origin: #{File.expand_path(playbook)}:8:17")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "runs a play-level run_once: task on the first host only, unless a task opts out" do
    playbook = File.tempname("run-once-play-valid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: threelocal
        gather_facts: false
        run_once: true
        tasks:
          - name: Play-level run_once
            ansible.builtin.debug:
              msg: "PLAY-LEVEL {{ inventory_hostname }}"
          - name: Opting out
            ansible.builtin.debug:
              msg: "OPTED-OUT {{ inventory_hostname }}"
            run_once: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", MULTI_HOST, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.must_include("PLAY-LEVEL nodea")
    output_text.wont_include("PLAY-LEVEL nodeb")
    # The task's own run_once: false still wins over the play's value.
    output_text.must_include("OPTED-OUT nodeb")
    output_text.must_include("OPTED-OUT nodec")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
