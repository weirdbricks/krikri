require "../spec_helper"

# ansible.mariadb.mariadb_db / mariadb_user - previously unimplemented
# collection modules (rc=4 "unavailable modules" where real ansible
# ran them; fauust.mariadb, round 6002). The real modules are
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
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

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

%w[ansible.mariadb.mariadb_db ansible.mariadb.mariadb_user mariadb_db mariadb_user].each do |module_name|
  describe "ansible.mariadb module resolution" do
    it "resolves #{module_name} without the unimplemented-plugin warning" do
      status, output = run_playbook(module_name)
      output.should_not contain("uses unimplemented plugin: #{module_name}")
      output.should_not contain("unavailable modules")
      # The task itself ran: its result is a DB outcome (failed on a
      # host with no reachable server, or a clean ok/changed), never a
      # parse-time refusal (rc=4 "unavailable modules").
      status.exit_code.should_not eq(4)
    end
  end
end
