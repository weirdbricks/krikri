require "../minitest_helper"

# ansible.mariadb.mariadb_db / mariadb_user - previously unimplemented
# collection modules (rc=4 "unavailable modules" where Ansible
# ran them; fauust.mariadb, round 6002). The Ansible modules are
# functionally identical forks of community.mysql's mysql_db/mysql_user
# (verified against both collections' sources), so they resolve through
# MODULE_ALIASES onto the existing plugin binaries.
#
# These specs pin the resolution: no parse-time "uses unimplemented
# plugin" warning, and the module actually dispatches (the task then
# fails/succeeds on its own DB merits, which is environment-dependent -
# the parse-time behavior is the thing under test here).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(module_name : String) : {Process::Status, String}
  playbook = File.tempname("mariadb-alias", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: mariadb module under test
          #{module_name}:
            name: specdb
            state: absent
    YAML
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# The classic suite looped module names around describe; minitest's
# describe/it macros cannot expand inside a runtime block, so the loop
# is unrolled into one it per module name.
describe "ansible.mariadb module resolution" do
  it "resolves ansible.mariadb.mariadb_db without the unimplemented-plugin warning" do
    status, output = run_playbook("ansible.mariadb.mariadb_db")
    output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_db")
    output.wont_include("unavailable modules")
    # The task itself ran: its result is a DB outcome (failed on a
    # host with no reachable server, or a clean ok/changed), never a
    # parse-time refusal (rc=4 "unavailable modules").
    status.exit_code.wont_equal(4)
  end

  it "resolves ansible.mariadb.mariadb_user without the unimplemented-plugin warning" do
    status, output = run_playbook("ansible.mariadb.mariadb_user")
    output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_user")
    output.wont_include("unavailable modules")
    status.exit_code.wont_equal(4)
  end

  it "resolves mariadb_db without the unimplemented-plugin warning" do
    status, output = run_playbook("mariadb_db")
    output.wont_include("uses unimplemented plugin: mariadb_db")
    output.wont_include("unavailable modules")
    status.exit_code.wont_equal(4)
  end

  it "resolves mariadb_user without the unimplemented-plugin warning" do
    status, output = run_playbook("mariadb_user")
    output.wont_include("uses unimplemented plugin: mariadb_user")
    output.wont_include("unavailable modules")
    status.exit_code.wont_equal(4)
  end
end
