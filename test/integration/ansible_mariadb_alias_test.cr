require "file_utils"
require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/collection_index"

# ansible.mariadb.mariadb_db / mariadb_user - aliased through
# MODULE_ALIASES onto community.mysql's mysql_db/mysql_user plugin
# binaries (the Ansible modules are functionally identical forks,
# verified against both collections' sources; fauust.mariadb, round
# 6002).
#
# The aliases are unconditional, like every other MODULE_ALIASES entry:
# krikri's behavior does not depend on what the controller has installed,
# so the four spellings resolve onto the community.mysql port here whether
# or not ansible.mariadb is present (real only resolves them where it is,
# issue #499 - see KNOWN_MISSING.md's "krikri never consults an installed
# ansible-core or collections tree").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(module_name : String, env : Hash(String, String)? = nil) : {Process::Status, String}
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
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured, env: env)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# The classic suite looped module names around describe; minitest's
# describe/it macros cannot expand inside a runtime block, so the loop
# is unrolled into one it per module name.
describe "ansible.mariadb module resolution" do
  it "runs ansible.mariadb.mariadb_db through the community.mysql port, never as unimplemented" do
    status, output = run_playbook("ansible.mariadb.mariadb_db")
    output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_db")
    output.wont_include("unavailable modules")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.wont_equal(4)
  end

  it "runs ansible.mariadb.mariadb_user through the community.mysql port" do
    status, output = run_playbook("ansible.mariadb.mariadb_user")
    output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_user")
    output.wont_include("unavailable modules")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.wont_equal(4)
  end

  it "runs bare mariadb_db through the community.mysql port" do
    status, output = run_playbook("mariadb_db")
    output.wont_include("uses unimplemented plugin: mariadb_db")
    output.wont_include("unavailable modules")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.wont_equal(4)
  end

  it "runs bare mariadb_user through the community.mysql port" do
    status, output = run_playbook("mariadb_user")
    output.wont_include("uses unimplemented plugin: mariadb_user")
    output.wont_include("unavailable modules")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.wont_equal(4)
  end

  it "keeps the alias when ANSIBLE_COLLECTIONS_PATH points at an empty tree" do
    # The pre-redesign index refused all four spellings on a controller
    # without ansible.mariadb, so the same playbook behaved differently
    # depending on the machine. Point the collection env at a tree whose
    # ansible.mariadb has no module file: the alias must still resolve.
    root = PluginSpecHelper.tmp_path("mariadb-empty-collections")
    FileUtils.mkdir_p(File.join(root, "ansible_collections", "ansible", "mariadb", "plugins", "modules"))
    status, output = run_playbook("ansible.mariadb.mariadb_db",
      {"ANSIBLE_COLLECTIONS_PATH" => root})
    output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_db")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.wont_equal(4)
  end

  it "runs ansible.mariadb.mariadb_db reached through include_tasks" do
    dir = File.tempname("mariadb-include")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "databases.yml"), <<-YAML)
        ---
        - name: Ensure MariaDB databases are present (or absent)
          ansible.mariadb.mariadb_db:
            name: specdb
            state: absent
        YAML
      playbook = File.join(dir, "play.yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: Include task databases.yml
              ansible.builtin.include_tasks: databases.yml
        YAML
      captured = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
      output = captured.to_s
      status.exit_code.wont_equal(4)
      output.wont_include("couldn't resolve module/action")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
