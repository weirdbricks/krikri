require "../minitest_helper"
require "file_utils"

# A play-level `include_vars: "<name>.yml"` is resolved through Ansible's
# _find_needle('vars', src), i.e. DataLoader.path_dwim_relative_stack: for
# every search-path base it tries <base>/vars/<src> before <base>/<src>.
# The playbook's own directory is such a base, so a bare filename loads the
# playbook directory's vars/ copy (live-verified vs ansible-core 2.21.6,
# issue #1194 - capitanh.rapiddeploy_ansible_role's OS-specific vars).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_play_include_vars_repro(src_dir : String) : String
  playbook = File.join(src_dir, "pb.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: Load a variable file
          include_vars: "shared-vars.yml"
        - name: Show it
          debug:
            msg: "{{ shared_setting }}"
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  raise "playbook failed with rc=#{status.exit_code}:\n#{output}" unless status.success?
  output.to_s
end

describe "include_vars: play-level lookup under the playbook's vars/ directory" do
  it "loads a bare filename from the playbook directory's vars/ subdirectory" do
    src_dir = PluginSpecHelper.tmp_path("include-vars-play-vars-dir")
    Dir.mkdir_p(File.join(src_dir, "vars"))
    File.write(File.join(src_dir, "vars", "shared-vars.yml"), "shared_setting: from_vars_dir\n")

    output = run_play_include_vars_repro(src_dir)

    output.must_include("ok: [localhost]")
    output.must_include(%("msg": "from_vars_dir"))
    output.wont_include("FAILED")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefers the playbook directory's vars/ copy over a bare same-named file" do
    src_dir = PluginSpecHelper.tmp_path("include-vars-play-vars-order")
    Dir.mkdir_p(File.join(src_dir, "vars"))
    File.write(File.join(src_dir, "shared-vars.yml"), "shared_setting: from_playbook_dir\n")
    File.write(File.join(src_dir, "vars", "shared-vars.yml"), "shared_setting: from_vars_dir\n")

    output = run_play_include_vars_repro(src_dir)

    output.must_include(%("msg": "from_vars_dir"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
