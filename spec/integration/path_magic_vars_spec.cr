require "../spec_helper"
require "file_utils"

# playbook_dir / inventory_dir / inventory_file - real Ansible's path
# magic vars. All three are absolute regardless of how the paths were
# spelled on the command line, verified against ansible-core 2.19.4 with
# a relative playbook and inventory invoked from a third directory.
# Found while building the community.crypto modules: `{{ playbook_dir }}`
# failed outright here with "'playbook_dir' is undefined".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private TMP_DIR      = File.join(PROJECT_ROOT, "spec", "tmp", "path_magic_vars")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(File.join(TMP_DIR, "sub"))
  File.write(File.join(TMP_DIR, "hosts.ini"), "localhost ansible_connection=local\n")
end

private def run_playbook(playbook : String, inventory : String, chdir : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, chdir: chdir)
  {status, output.to_s}
end

private PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: report
        ansible.builtin.debug:
          msg: "PD=[{{ playbook_dir }}] ID=[{{ inventory_dir }}] IF=[{{ inventory_file }}]"
  YAML

describe "path magic vars" do
  it "defines playbook_dir, inventory_dir and inventory_file as absolute paths" do
    playbook = File.join(TMP_DIR, "sub", "play.yml")
    File.write(playbook, PLAYBOOK)
    inventory = File.join(TMP_DIR, "hosts.ini")

    status, output = run_playbook(playbook, inventory, TMP_DIR)

    status.exit_code.should eq(0)
    output.should contain("PD=[#{File.join(TMP_DIR, "sub")}]")
    output.should contain("ID=[#{TMP_DIR}]")
    output.should contain("IF=[#{inventory}]")
  end

  # The paths must not follow the working directory or stay relative:
  # a role's `{{ playbook_dir }}/files/x` has to resolve the same way
  # no matter where ansible-playbook was invoked from.
  it "resolves them from the playbook and inventory, not the working directory" do
    playbook = File.join(TMP_DIR, "sub", "play.yml")
    inventory = File.join(TMP_DIR, "hosts.ini")

    status, output = run_playbook(playbook, inventory, "/tmp")

    status.exit_code.should eq(0)
    output.should contain("PD=[#{File.join(TMP_DIR, "sub")}]")
    output.should contain("ID=[#{TMP_DIR}]")
  end

  it "resolves a relative playbook path to an absolute playbook_dir" do
    playbook = File.join(TMP_DIR, "sub", "play.yml")
    File.write(playbook, PLAYBOOK)

    status, output = run_playbook(File.join("sub", "play.yml"), "hosts.ini", TMP_DIR)

    status.exit_code.should eq(0)
    output.should contain("PD=[#{File.join(TMP_DIR, "sub")}]")
    output.should contain("IF=[#{File.join(TMP_DIR, "hosts.ini")}]")
  end

  it "makes them available to handlers as well as tasks" do
    playbook = File.join(TMP_DIR, "handler.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.command: echo hi
            notify: report path
        handlers:
          - name: report path
            ansible.builtin.debug:
              msg: "HANDLER_PD=[{{ playbook_dir }}]"
      YAML

    status, output = run_playbook(playbook, File.join(TMP_DIR, "hosts.ini"), TMP_DIR)

    status.exit_code.should eq(0)
    output.should contain("HANDLER_PD=[#{TMP_DIR}]")
  end
end
