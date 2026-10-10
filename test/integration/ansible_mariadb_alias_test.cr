require "../minitest_helper"

# ansible.mariadb.mariadb_db / mariadb_user - functionally identical
# forks of community.mysql's mysql_db/mysql_user (verified against both
# collections' sources), aliased onto the existing plugin binaries in
# MODULE_ALIASES (fauust.mariadb, round 6002).
#
# With controller collection-set awareness these spellings are dead
# aliases on this controller, exactly as they are for ansible-core
# (live-verified vs 2.19.11): ansible.mariadb is not installed, and the
# bare spellings carry no ansible_builtin_runtime.yml redirect, so real
# refuses the whole playbook at load with the generic couldn't-resolve
# wording (rc=4, zero tasks run). The aliases stay in the table as dead
# code for controllers that DO have the collection installed; these
# specs now pin the refusal.
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
  {% for module_name in ["ansible.mariadb.mariadb_db", "ansible.mariadb.mariadb_user", "mariadb_db", "mariadb_user"] %}
    it "refuses {{ module_name.id }} at load, matching ansible-core (collection not installed / no redirect)" do
      status, output = run_playbook({{ module_name }})
      status.exit_code.must_equal(4, output)
      output.must_include("couldn't resolve module/action '{{ module_name.id }}'. " +
                          "This often indicates a misspelling, missing collection, or incorrect module path.")
      output.wont_include("PLAY RECAP")
    end
  {% end %}
end
