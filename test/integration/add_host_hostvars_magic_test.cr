require "../minitest_helper"

# Pins the hostvars entry of an add_host-created host against
# ansible-core 2.19.11 (live-verified via
# `{{ hostvars['dyn1'] | dictsort | to_json }}`): the entry carries the
# play magic variables real defines on every hostvars entry -
# inventory_hostname/_short, group_names (THE NEW HOST's groups, not the
# reading host's), groups, playbook_dir, inventory_dir/inventory_file,
# ansible_version, ansible_check_mode/diff_mode, ansible_forks,
# ansible_play_name, ansible_inventory_sources, ansible_run_tags/
# ansible_skip_tags, ansible_verbosity, ansible_play_hosts_all/
# ansible_play_hosts/play_hosts - alongside the host's own vars.
# ansible_playbook_python and ansible_config_file are not synthesized
# (this engine defines neither anywhere).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_two_play_and_dump : JSON::Any
  dump = PluginSpecHelper.tmp_path("addhost-hostvars-#{Random::Secure.hex(4)}.json")
  inventory = PluginSpecHelper.tmp_path("addhost-hostvars.inv")
  File.write(inventory, "control1 ansible_connection=local\n")
  playbook = PluginSpecHelper.tmp_path("addhost-hostvars.yml")
  File.write(playbook, <<-YAML)
    - hosts: control1
      gather_facts: false
      connection: local
      tasks:
        - ansible.builtin.add_host:
            name: dyn1.example.com
            groups: newgrp
            ansible_host: 1.2.3.4

    - hosts: control1
      gather_facts: false
      connection: local
      tasks:
        - name: dump
          ansible.builtin.copy:
            content: |-
              {{ hostvars['dyn1.example.com'] | to_json }}
            dest: #{dump}
    YAML
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  unless status.success?
    raise "krikri-playbook failed: #{output}"
  end
  JSON.parse(File.read(dump))
end

describe "add_host hostvars magic variables" do
  it "carries the new host's own per-host magic vars, not the reading host's" do
    entry = run_two_play_and_dump.as_h

    entry["inventory_hostname"].as_s.must_equal("dyn1.example.com")
    entry["inventory_hostname_short"].as_s.must_equal("dyn1")
    entry["group_names"].as_a.map(&.as_s).must_equal(["newgrp"])
    entry["ansible_host"].as_s.must_equal("1.2.3.4")
  end

  it "carries the play-scoped magic vars" do
    entry = run_two_play_and_dump.as_h

    groups = entry["groups"].as_h
    groups["newgrp"].as_a.map(&.as_s).must_equal(["dyn1.example.com"])
    groups.has_key?("all").must_equal(true)

    entry.has_key?("playbook_dir").must_equal(true)
    entry.has_key?("inventory_dir").must_equal(true)
    entry["inventory_file"].as_s.must_equal(File.expand_path(PluginSpecHelper.tmp_path("addhost-hostvars.inv")))

    version = entry["ansible_version"].as_h
    version.has_key?("full").must_equal(true)
    version.has_key?("major").must_equal(true)

    entry["ansible_check_mode"].as_bool.must_equal(false)
    entry["ansible_diff_mode"].as_bool.must_equal(false)
    entry["ansible_verbosity"].as_i.must_equal(0)
    entry["ansible_forks"].as_i.must_equal(5)
    entry.has_key?("ansible_play_name").must_equal(true)
    # Real carries the ansible_facts dict form even when nothing was
    # gathered (empty dict) - live-verified vs 2.19.11.
    entry["ansible_facts"].as_h.size.must_equal(0)
    entry["ansible_run_tags"].as_a.map(&.as_s).must_equal(["all"])
    entry["ansible_skip_tags"].as_a.size.must_equal(0)
    entry.has_key?("ansible_inventory_sources").must_equal(true)

    # The READING play's host list (real: play-scoped), not the inventory.
    entry["ansible_play_hosts_all"].as_a.map(&.as_s).must_equal(["control1"])
    entry["ansible_play_hosts"].as_a.map(&.as_s).must_equal(["control1"])
    entry["play_hosts"].as_a.map(&.as_s).must_equal(["control1"])
  end

  it "does not fabricate ansible_playbook_python or ansible_config_file" do
    entry = run_two_play_and_dump.as_h

    entry.has_key?("ansible_playbook_python").must_equal(false)
    entry.has_key?("ansible_config_file").must_equal(false)
  end
end
