require "../minitest_helper"
require "file_utils"

# community.general.nsupdate (11.2.1, the sweep environment's) hands the
# `server` parameter straight to dnspython's dns.query.udp/tcp, whose
# dns.inet.af_for_address accepts an IPv4/IPv6 LITERAL only and otherwise
# raises a bare ValueError from inside an `except SyntaxError` block.
# nsupdate.py catches only OSError/dns.exception.Timeout, so a hostname (or
# any non-literal, e.g. `server: 19`) ends the module with an uncaught,
# message-less exception: Ansible's fatal msg is the bare
# "Task failed: Module failed." and, because Python hangs the implicit
# __context__ off that exception, its [ERROR] block splits into a second
# segment plus an empty "<<< caused by >>>" leaf (kpg
# 000015-multi-pam_limits-chaos, live-verified vs ansible-core 2.21.6).
describe "nsupdate non-IP server crash" do
  it "fails like dnspython's literal-only server check, without a msg" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "localhost", "record" => "33", "zone" => "kpg-test.zone",
      "state" => "absent", "ttl" => "60", "type" => "A", "protocol" => "udp",
      "value" => "szvmty", "_ansible_check_mode" => "true",
    }, collection_version: "11.2.1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed.")
    result["_ansible_error_detail"].as_s.must_equal("")
    result["_ansible_crash_context"].as_bool.must_equal(true)
  end

  it "crashes the same way when the zone has to be looked up first" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "19", "record" => "host.example.com.", "value" => "192.168.1.9",
    }, collection_version: "11.2.1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed.")
    result["_ansible_crash_context"].as_bool.must_equal(true)
  end
end

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-localhost-local.ini")

# The 11.2.x message-less crash (covered at the plugin level above by
# forcing `collection_version: "11.2.1"`) is NOT reproducible end to end:
# krikri models its BAKED community.general release (12.5.0), whose nsupdate
# fails with an inlined msg instead of the bare "Module failed.". That is
# exactly real's 12.5.0 behaviour (live-verified vs ansible-core 2.21.6),
# and krikri reaches it no matter what ANSIBLE_COLLECTIONS_PATH points at -
# so the fixture tree below is there to prove it is IGNORED, not to steer
# the answer (see KNOWN_MISSING "krikri never consults an installed
# ansible-core or collections tree").
describe "nsupdate non-IP server resolves the baked release, not the controller's tree" do
  it "models 12.5.0 (inlined msg) though an 11.2.1 tree is on the search path" do
    root = PluginSpecHelper.tmp_path("nsupdate-11.2.1-tree")
    general = File.join(root, "ansible_collections", "community", "general")
    FileUtils.mkdir_p(File.join(general, "plugins", "modules"))
    File.write(File.join(general, "MANIFEST.json"),
      %({"collection_info": {"namespace": "community", "name": "general", "version": "11.2.1"}}))
    # The FQCN only has to RESOLVE for the playbook to load - krikri runs its
    # own native nsupdate plugin, never this file.
    File.write(File.join(general, "plugins", "modules", "nsupdate.py"), "# fixture module\n")

    playbook = File.join(root, "pb.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: nsupdate non-IP server
            community.general.nsupdate:
              protocol: udp
              record: 33
              server: localhost
              state: absent
              ttl: 60
              type: A
              value: szvmty
              zone: kpg-test.zone
            ignore_errors: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"],
      output: output, error: output, input: IO::Memory.new,
      env: ENV.to_h.merge({"ANSIBLE_COLLECTIONS_PATH" => root}))

    status.success?.must_equal(true)
    text = output.to_s
    # 12.5.0 inlines the module msg (the exact DNS text depends on the local
    # resolver, so only pin the stable shape: the single "[ERROR] ... Module
    # failed: <msg>" segment, its Origin, no two-segment crash split, and the
    # fatal's msg carried through).
    text.must_include("[ERROR]: Task failed: Module failed:")
    text.must_include("Origin: #{playbook}:6:7\n")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": ))
    text.must_include("\n...ignoring\n")
    text.wont_include("<<< caused by >>>")
  end
end
