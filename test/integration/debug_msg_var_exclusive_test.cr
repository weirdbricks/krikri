require "../minitest_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible (verified against ansible-core 2.19.11) fails the task
# through debug's own argument-spec validation with "parameters are
# mutually exclusive: msg|var" when both are given; this engine happily
# printed the var and succeeded.
describe "debug: msg and var mutually exclusive" do
  it "fails the task when both msg and var are given" do
    playbook = File.tempname("debug-exclusive", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: both msg and var
            ansible.builtin.debug:
              msg: "hello"
              var: playbook_dir
            register: r
            ignore_errors: true
          - name: show result
            ansible.builtin.debug:
              msg: "RESULT failed={{ r.failed | default(false) }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("parameters are mutually exclusive: msg|var")
    output.to_s.must_include("RESULT failed=True")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
