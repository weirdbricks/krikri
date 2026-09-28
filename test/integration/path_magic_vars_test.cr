require "../minitest_helper"
require "file_utils"

# playbook_dir / inventory_dir / inventory_file - real Ansible's path
# magic vars. All three are absolute regardless of how the paths were
# spelled on the command line, verified against ansible-core 2.19.4 with
# a relative playbook and inventory invoked from a third directory.
# Found while building the community.crypto modules: `{{ playbook_dir }}`
# failed outright here with "'playbook_dir' is undefined".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# The classic suite built the shared spec/tmp/path_magic_vars tree once
# in before_suite; each minitest test rebuilds it inside its own
# tmp_path subtree (the tree is read by the child process via chdir).
private def tmp_dir : String
  dir = PluginSpecHelper.tmp_path("path_magic_vars")
  FileUtils.mkdir_p(File.join(dir, "sub"))
  File.write(File.join(dir, "hosts.ini"), "localhost ansible_connection=local\n")
  dir
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
    playbook = File.join(tmp_dir, "sub", "play.yml")
    File.write(playbook, PLAYBOOK)
    inventory = File.join(tmp_dir, "hosts.ini")

    status, output = run_playbook(playbook, inventory, tmp_dir)

    status.exit_code.must_equal(0)
    output.must_include("PD=[#{File.join(tmp_dir, "sub")}]")
    output.must_include("ID=[#{tmp_dir}]")
    output.must_include("IF=[#{inventory}]")
  end

  # The paths must not follow the working directory or stay relative:
  # a role's `{{ playbook_dir }}/files/x` has to resolve the same way
  # no matter where ansible-playbook was invoked from.
  it "resolves them from the playbook and inventory, not the working directory" do
    playbook = File.join(tmp_dir, "sub", "play.yml")
    File.write(playbook, PLAYBOOK)
    inventory = File.join(tmp_dir, "hosts.ini")

    status, output = run_playbook(playbook, inventory, "/tmp")

    status.exit_code.must_equal(0)
    output.must_include("PD=[#{File.join(tmp_dir, "sub")}]")
    output.must_include("ID=[#{tmp_dir}]")
  end

  it "resolves a relative playbook path to an absolute playbook_dir" do
    playbook = File.join(tmp_dir, "sub", "play.yml")
    File.write(playbook, PLAYBOOK)

    status, output = run_playbook(File.join("sub", "play.yml"), "hosts.ini", tmp_dir)

    status.exit_code.must_equal(0)
    output.must_include("PD=[#{File.join(tmp_dir, "sub")}]")
    output.must_include("IF=[#{File.join(tmp_dir, "hosts.ini")}]")
  end

  it "makes them available to handlers as well as tasks" do
    playbook = File.join(tmp_dir, "handler.yml")
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

    status, output = run_playbook(playbook, File.join(tmp_dir, "hosts.ini"), tmp_dir)

    status.exit_code.must_equal(0)
    output.must_include("HANDLER_PD=[#{tmp_dir}]")
  end
end
