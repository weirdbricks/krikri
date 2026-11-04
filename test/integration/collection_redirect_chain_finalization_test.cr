require "../minitest_helper"

# A collection's OWN meta/runtime.yml redirect is the second hop of the
# chain the task-args finalization error reports the end of. The first
# hop is ansible-core's builtin runtime (ansible_builtin_runtime.yml),
# which still routes the legacy bare `hcloud_ssh_key` spelling onto
# hetzner.hcloud.hcloud_ssh_key - but hetzner.hcloud 7.x renames its
# modules back onto unprefixed files in its own runtime.yml
# (hcloud_ssh_key -> ssh_key). Real ansible 2.19.11 reports the chain END
# ('hetzner.hcloud.ssh_key') in the finalization error, for the bare
# spelling AND for the legacy FQCN spelling alike; krikri used to stop at
# the first hop and report the intermediate FQCN (issue #800,
# siw36.ansible_hcloud_vm).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("collection-redirect-chain", ".yml")
  File.write(playbook, yaml)
  fixture_root = File.tempname("collection-redirect-collections")
  collection = File.join(fixture_root, "ansible_collections", "hetzner", "hcloud")
  FileUtils.mkdir_p(File.join(collection, "plugins", "modules"))
  FileUtils.mkdir_p(File.join(collection, "meta"))
  File.write(File.join(collection, "meta", "runtime.yml"), <<-YAML
    plugin_routing:
      modules:
        hcloud_ssh_key:
          redirect: hetzner.hcloud.ssh_key
        hcloud_ssh_key_info:
          redirect: hetzner.hcloud.ssh_key_info
    YAML
  )
  ["ssh_key.py", "ssh_key_info.py"].each do |leaf|
    File.write(File.join(collection, "plugins", "modules", leaf), "#!/usr/bin/python\n")
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
    env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  FileUtils.rm_r(fixture_root) if fixture_root && Dir.exists?(fixture_root)
end

describe "collection redirect chain finalization" do
  it "names the chain end for a bare legacy collection module" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on collection-redirected module
            hcloud_ssh_key:
              api_token: "{{ hcloudBearer }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'hetzner.hcloud.ssh_key' failed: Error while resolving value for 'api_token': 'hcloudBearer' is undefined")
    # The intermediate builtin-runtime hop must not leak into the message.
    output.wont_include("Finalization of task args for 'hetzner.hcloud.hcloud_ssh_key'")
    output.must_include("failed=1")
    # A failed task halts the host, so the sentinel task never runs.
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "names the chain end for the legacy FQCN spelling too" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on collection-redirected module, FQCN spelling
            hetzner.hcloud.hcloud_ssh_key:
              api_token: "{{ hcloudBearer }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'hetzner.hcloud.ssh_key' failed: Error while resolving value for 'api_token': 'hcloudBearer' is undefined")
    output.wont_include("Finalization of task args for 'hetzner.hcloud.hcloud_ssh_key'")
    output.must_include("failed=1")
    output.wont_include("SHOULD-RUN-AFTER")
  end

  it "keeps an as-written canonical collection module name unchanged" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on canonical collection module
            hetzner.hcloud.ssh_key:
              api_token: "{{ hcloudBearer }}"
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'hetzner.hcloud.ssh_key' failed: Error while resolving value for 'api_token': 'hcloudBearer' is undefined")
    output.must_include("failed=1")
    output.wont_include("SHOULD-RUN-AFTER")
  end
end
