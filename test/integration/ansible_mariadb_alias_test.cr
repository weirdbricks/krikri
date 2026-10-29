require "file_utils"
require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/collection_index"

# ansible.mariadb.mariadb_db / mariadb_user - aliased through
# MODULE_ALIASES onto community.mysql's mysql_db/mysql_user plugin
# binaries (the Ansible modules are functionally identical forks,
# verified against both collections' sources; fauust.mariadb, round
# 6002). The aliases are only live where the controller actually has
# ansible.mariadb: without it real refuses the whole playbook at load
# (rc=4, "couldn't resolve module/action ...", issue #499), so the
# parse-time controller-collection refusal covers all four spellings
# (MARIADB_FORK_ALIASES) too - the alias must not exempt a name real
# cannot even resolve.
#
# The controller's collection state decides which half of the behavior
# the specs pin: refusal (with the as-written name in the message and
# the loader's [WARNING] line for the FQCN spellings) where the
# collection is absent, live aliasing where it is present or the
# controller state is unsure.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def mariadb_collection_state : Bool?
  Krikri::CollectionIndex.controller_resolves?("ansible.mariadb.mariadb_db")[:resolves]
end

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
  it "refuses ansible.mariadb.mariadb_db at load (rc=4) on a controller without the collection" do
    if mariadb_collection_state == false
      status, output = run_playbook("ansible.mariadb.mariadb_db")
      status.exit_code.must_equal(4, output)
      output.must_include("[WARNING]: Error loading plugin 'ansible.mariadb.mariadb_db': No module named 'ansible_collections.ansible.mariadb'")
      output.must_include("[ERROR]: couldn't resolve module/action 'ansible.mariadb.mariadb_db'. This often indicates a misspelling, missing collection, or incorrect module path.")
      output.wont_include("PLAY RECAP")
    else
      status, output = run_playbook("ansible.mariadb.mariadb_db")
      output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_db")
      output.wont_include("unavailable modules")
      status.exit_code.wont_equal(4)
    end
  end

  it "refuses ansible.mariadb.mariadb_user at load (rc=4) on a controller without the collection" do
    if mariadb_collection_state == false
      status, output = run_playbook("ansible.mariadb.mariadb_user")
      status.exit_code.must_equal(4, output)
      output.must_include("[WARNING]: Error loading plugin 'ansible.mariadb.mariadb_user': No module named 'ansible_collections.ansible.mariadb'")
      output.must_include("[ERROR]: couldn't resolve module/action 'ansible.mariadb.mariadb_user'. This often indicates a misspelling, missing collection, or incorrect module path.")
      output.wont_include("PLAY RECAP")
    else
      status, output = run_playbook("ansible.mariadb.mariadb_user")
      output.wont_include("uses unimplemented plugin: ansible.mariadb.mariadb_user")
      output.wont_include("unavailable modules")
      status.exit_code.wont_equal(4)
    end
  end

  it "refuses bare mariadb_db at load (rc=4) on a controller without the collection, no warning" do
    if mariadb_collection_state == false
      status, output = run_playbook("mariadb_db")
      status.exit_code.must_equal(4, output)
      output.wont_include("[WARNING]: Error loading plugin")
      output.must_include("[ERROR]: couldn't resolve module/action 'mariadb_db'. This often indicates a misspelling, missing collection, or incorrect module path.")
      output.wont_include("PLAY RECAP")
    else
      status, output = run_playbook("mariadb_db")
      output.wont_include("uses unimplemented plugin: mariadb_db")
      output.wont_include("unavailable modules")
      status.exit_code.wont_equal(4)
    end
  end

  it "refuses ansible.mariadb.mariadb_db reached through include_tasks (rc=4) on a controller without the collection" do
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
      if mariadb_collection_state == false
        status.exit_code.must_equal(4, output)
        output.must_include("[ERROR]: couldn't resolve module/action 'ansible.mariadb.mariadb_db'. This often indicates a misspelling, missing collection, or incorrect module path.")
        output.wont_include("PLAY RECAP")
      else
        status.exit_code.wont_equal(4)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "refuses bare mariadb_user at load (rc=4) on a controller without the collection, no warning" do
    if mariadb_collection_state == false
      status, output = run_playbook("mariadb_user")
      status.exit_code.must_equal(4, output)
      output.wont_include("[WARNING]: Error loading plugin")
      output.must_include("[ERROR]: couldn't resolve module/action 'mariadb_user'. This often indicates a misspelling, missing collection, or incorrect module path.")
      output.wont_include("PLAY RECAP")
    else
      status, output = run_playbook("mariadb_user")
      output.wont_include("uses unimplemented plugin: mariadb_user")
      output.wont_include("unavailable modules")
      status.exit_code.wont_equal(4)
    end
  end
end
