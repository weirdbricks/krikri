require "../minitest_helper"
require "../../src/krikri/variable_substitutor/jinja_renderer"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# znerol.ssh_kba (round 5460170): the role's vars/main.yml builds
# `ssh_kba_server_host_names_and_keys` through a four-level lazy-var chain
# (names_and_keys -> _nxk_names -> _nxk -> defaults' host_names/host_keys
# -> hostname), and the `SSH host keys registered at client` task iterates
# it via `loop: >- {{ ssh_kba_server_host_names_and_keys }}`. The engine's
# variable-preparation runaway guard was a flat depth cap of 3 nested
# prepare_var levels, so the innermost var reached the engine as its
# still-templated raw text; `hostvars[ssh_kba_server_hostname][...]` then
# looked up the literal string "{{ inventory_hostname }}" as a host name,
# every `| default(False)` ternary went false, the cartesian product
# collapsed to [], and the loop resolved to zero items - task skipped
# where ansible-playbook 2.19.11 runs all six items (cold: changed=3 vs
# changed=2, warm: ok=10 vs ok=9 in the round recap). Ansible resolves
# lazy chains recursively with cycle detection, not a depth cap - the
# guard now fires on a REPEATING name instead.

private def deep_chain_vars : Hash(String, JSON::Any)
  vars = Hash(String, JSON::Any).new
  vars["inventory_hostname"] = JSON::Any.new("testhost")
  vars["sshkba_hostname"] = JSON.parse(%q("{{ inventory_hostname }}"))
  vars["sshkba_hostnames"] = JSON.parse(%q("{{ [sshkba_hostname, '1.2.3.4'] | select() | list }}"))
  vars["sshkba_host_keys"] = JSON.parse(%q("{{ ['ecdsa AAAA', 'ed25519 BBBB'] | select() | list }}"))
  vars["sshkba_nxk"] = JSON.parse(%q("{{ query('cartesian', sshkba_hostnames, sshkba_host_keys) }}"))
  vars["sshkba_nxk_names"] = JSON.parse(%q("{{ sshkba_nxk | map('first') | list }}"))
  vars["sshkba_nxk_keys"] = JSON.parse(%q("{{ sshkba_nxk | map('join', ' ') | list }}"))
  vars["sshkba_names_and_keys"] = JSON.parse(
    %q("{{ sshkba_nxk_names | zip(sshkba_nxk_keys) | list }}"))
  vars
end

describe "deep lazy-var chain variable preparation" do
  it "renders a four-level distinct-name chain to full depth through the engine" do
    # The engine path the loop source actually takes
    # (resolve_template_value -> evaluate_bare_mustache_preserving_type ->
    # JinjaRenderer.evaluate_structured): under the old depth cap the
    # 4th-level var came back as raw template text and the whole chain
    # collapsed to [].
    value = Krikri::VariableSubstitutor::JinjaRenderer.evaluate_structured(
      "sshkba_names_and_keys", deep_chain_vars, strict: true)
    expected = <<-JSON
      [
        ["testhost", "testhost ecdsa AAAA"],
        ["testhost", "testhost ed25519 BBBB"],
        ["1.2.3.4", "1.2.3.4 ecdsa AAAA"],
        ["1.2.3.4", "1.2.3.4 ed25519 BBBB"]
      ]
      JSON
    value.must_equal(JSON.parse(expected))
  end

  it "runs the role's own looped task over the deep chain, not skipping it" do
    # End-to-end: same shape as the diverging task, with the ternary-
    # guarded host_keys defaults and the folded `loop: >-` source.
    root = PluginSpecHelper.tmp_path("prepare_vars_deep_chain")
    role_dir = File.join(root, "roles", "deepchain")
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    Dir.mkdir_p(File.join(role_dir, "vars"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))

    File.write(File.join(role_dir, "defaults", "main.yml"), <<-YAML)
      ---
      sshkba_hostname: "{{ inventory_hostname }}"
      sshkba_hostnames: "{{ [hostvars[sshkba_hostname]['sshkba_fact_ecdsa'], '1.2.3.4'] | select() | list }}"
      sshkba_host_keys: "{{ [
            ('ecdsa', hostvars[sshkba_hostname]['sshkba_fact_ecdsa']) if hostvars[sshkba_hostname]['sshkba_fact_ecdsa'] | default(False) else (),
            ('ed25519', hostvars[sshkba_hostname]['sshkba_fact_ed25519']) if hostvars[sshkba_hostname]['sshkba_fact_ed25519'] | default(False) else (),
         ] | select() | map('join', ' ') | list
      }}"
      YAML
    File.write(File.join(role_dir, "vars", "main.yml"), <<-YAML)
      ---
      sshkba_nxk: "{{ query('cartesian', sshkba_hostnames, sshkba_host_keys) }}"
      sshkba_nxk_names: "{{ sshkba_nxk | map('first') | list }}"
      sshkba_nxk_keys: "{{ sshkba_nxk | map('join', ' ') | list }}"
      sshkba_names_and_keys: "{{ sshkba_nxk_names | zip(sshkba_nxk_keys) | list }}"
      YAML
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
      ---
      - name: deep chain loop
        debug:
          msg: "{{ item }}"
        loop: >-
          {{ sshkba_names_and_keys }}
      YAML

    inventory = File.join(root, "inventory.ini")
    File.write(inventory, <<-INI)
      [target]
      testhost ansible_connection=local sshkba_fact_ecdsa=AAAA sshkba_fact_ed25519=BBBB
      INI
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: target
        gather_facts: false
        roles:
          - deepchain
      YAML

    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: out_io, error: err_io)
    out = out_io.to_s

    status.success?.must_equal true, "playbook failed: #{err_io}"
    # The 2x2 product, in the role's own item shape (name, "name key").
    out.scan(/item=\[.*?\]/).map(&.[0]).must_equal([
      "item=['AAAA', 'AAAA ecdsa AAAA']",
      "item=['AAAA', 'AAAA ed25519 BBBB']",
      "item=['1.2.3.4', '1.2.3.4 ecdsa AAAA']",
      "item=['1.2.3.4', '1.2.3.4 ed25519 BBBB']",
    ])
    out.includes?("skipping: [testhost]").must_equal false,
      "loop resolved empty under the old depth cap: #{out}"
  end
end
