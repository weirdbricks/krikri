require "../minitest_helper"
require "file_utils"

# The iptables plugin shells out to the real binary for every operation
# (-C/-A/-D all need CAP_NET_ADMIN, unavailable in the spec sandbox), so
# only the argument-shape failures that Ansible raises BEFORE touching the
# binary are spec'd here - which is exactly the class the kpg32 seed-32
# sweep turned up. Each expectation was live-verified against
# ansible-core 2.19.11 with the real binary reachable.
describe "iptables plugin (pre-execution argument failures)" do
  # Both are uncaught exceptions inside Ansible's own construct_rule(): the
  # args dict's `rule=' '.join(construct_rule(module.params))` runs before
  # the module ever resolves the iptables binary, so a target without
  # iptables installed still reports these two verbatim.
  it "fails with Ansible's join TypeError when tcp_flags lacks a suboption" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "tcp_flags" => %({"flags": ["SYN"]}),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: can only join an iterable")
  end

  it "fails with Ansible's NoneType join error when match_set has no match_set_flags" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "match_set" => "admin_hosts",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: sequence item 4: expected str instance, NoneType found")
  end

  # real main() builds the rule BEFORE its log-jump enforcement, so the
  # construct_rule crash wins over the log-jump failure. krikri used to
  # check log-jump first and reported the wrong message.
  it "reports the construct_rule crash ahead of the log-jump failure" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "tcp_flags" => "{}", "log_level" => "debug", "jump" => "DROP",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: can only join an iterable")
  end

  # The log-jump failure itself, when the rule itself is well-formed.
  it "still reports Ansible's log-jump failure for a well-formed rule" do
    result = PluginSpecHelper.run("iptables", {
      "chain" => "INPUT", "state" => "absent",
      "log_level" => "debug", "jump" => "DROP",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Logging options can only be used with the LOG jump target.")
  end
end

# The two divergences the 1100001 kop_iptables probe round found against
# ansible-core 2.19.11 (~/scratch/probe-evidence/1100001_atlantic_local_kop_iptables):
# the registered `rule` string must be Ansible's raw `' '.join()` argv
# (a comment value reaches it unquoted), and a failed iptables invocation
# must carry the full module.run_command(check_rc=True) failure shape
# (cmd/rc/stdout/stderr/failed/msg/stdout_lines/stderr_lines/changed/
# exception), not the bare failed/msg/changed/exception fail_json shape.
# A shim `iptables` binary stands in for the real one (CAP_NET_ADMIN is
# unavailable in the spec sandbox); the shim fails exactly the way real
# iptables v1.8.7 does for a nonexistent jump target.
describe "iptables plugin run_command failure shape and raw rule string (probe 1100001)" do
  serial!

  private BINARY    = File.expand_path("../../bin/krikri-playbook", __DIR__)
  private INVENTORY = File.expand_path("../fixtures/inventory-explicit-localhost.ini", __DIR__)

  IPTABLES_FAIL_SHIM = <<-'SH'
    #!/bin/sh
    case "$*" in
      *KOP_NO_SUCH_TARGET*)
        echo "iptables v1.8.7 (nf_tables): Chain 'KOP_NO_SUCH_TARGET' does not exist" >&2
        echo "Try \`iptables -h' or 'iptables --help' for more information." >&2
        exit 2
        ;;
    esac
    exit 0
    SH

  private def with_iptables_shim(&)
    bin_dir = File.tempname("krikri-iptables-shape-shim")
    Dir.mkdir_p(bin_dir)
    binary = File.join(bin_dir, "iptables")
    File.write(binary, IPTABLES_FAIL_SHIM)
    File.chmod(binary, 0o755)
    previous_path = ENV["PATH"]?
    ENV["PATH"] = "#{bin_dir}:/usr/bin:/bin"
    begin
      yield bin_dir
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      FileUtils.rm_r(bin_dir)
    end
  end

  # Runs a playbook whose final task copies `{{ r | to_json }}` into a
  # file, returning the dumped object (writing the dump through copy:
  # avoids the display layer's JSON escaping entirely).
  private def run_probe_registered_dump(yaml : String) : JSON::Any
    dump = PluginSpecHelper.tmp_path("iptables-probe-dump.json")
    playbook = File.tempname("iptables-probe", ".yml")
    File.write(playbook, yaml.gsub("KRIKRI_DUMP_PATH", dump))
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s[-800..]? || output.to_s)
    JSON.parse(File.read(dump))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers a bad jump target failure with Ansible's full run_command shape" do
    with_iptables_shim do
      result = run_probe_registered_dump(<<-YAML
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: fail it
              ansible.builtin.iptables:
                chain: KOP_TEST
                protocol: tcp
                jump: KOP_NO_SUCH_TARGET
                destination_port: "8083"
              register: r
              ignore_errors: true
            - name: dump
              ansible.builtin.copy:
                content: |-
                  {{ r | to_json }}
                dest: KRIKRI_DUMP_PATH
        YAML
      )

      result.as_h.keys.must_equal(%w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception])
      result["rc"].as_i.must_equal(2)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal("iptables v1.8.7 (nf_tables): Chain 'KOP_NO_SUCH_TARGET' does not exist\nTry `iptables -h' or 'iptables --help' for more information.\n")
      result["msg"].as_s.must_equal("iptables v1.8.7 (nf_tables): Chain 'KOP_NO_SUCH_TARGET' does not exist\nTry `iptables -h' or 'iptables --help' for more information.")
      result["stdout_lines"].as_a.map(&.as_s).must_equal([] of String)
      result["stderr_lines"].as_a.map(&.as_s).must_equal([
        "iptables v1.8.7 (nf_tables): Chain 'KOP_NO_SUCH_TARGET' does not exist",
        "Try `iptables -h' or 'iptables --help' for more information.",
      ])
      result["changed"].as_bool.must_equal(false)
      result["exception"].as_s.must_equal("(traceback unavailable)")
      # The bare-name shim is resolved through PATH; the framing and the
      # raw (unquoted) rule tail must match Ansible's _clean_args join.
      result["cmd"].as_s.must_match(/-t filter -A KOP_TEST -p tcp -j KOP_NO_SUCH_TARGET --destination-port 8083\z/)
    end
  end

  it "registers a successful rule append with the raw unquoted rule string" do
    with_iptables_shim do
      result = run_probe_registered_dump(<<-YAML
        - name: repro
          hosts: localhost
          gather_facts: false
          connection: local
          tasks:
            - name: append it
              ansible.builtin.iptables:
                chain: KOP_TEST
                protocol: tcp
                jump: ACCEPT
                destination_port: "8080"
                comment: kop keyorder probe
              register: r
            - name: dump
              ansible.builtin.copy:
                content: |-
                  {{ r | to_json }}
                dest: KRIKRI_DUMP_PATH
        YAML
      )

      result["rule"].as_s.must_equal("-p tcp -j ACCEPT --destination-port 8080 -m comment --comment kop keyorder probe")
    end
  end
end
