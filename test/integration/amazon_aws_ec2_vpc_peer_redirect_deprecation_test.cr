require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19.11's console output for amazon.aws.ec2_vpc_peer's
# meta/runtime.yml rename deprecation (amazon.aws 10.1.1, live-verified
# against ansible-playbook with the mateothegreat.aws_vpc_create role's
# own bare spelling, ANSIBLE_NOCOLOR=1, tmp paths masked):
#
#   [WARNING]: Deprecation warnings can be disabled by setting
#   `deprecation_warnings=False` in ansible.cfg.
#   [DEPRECATION WARNING]: amazon.aws.ec2_vpc_peer has been deprecated.
#   ec2_vpc_peer has been renamed to ec2_vpc_peering. Please update your
#   tasks. This feature will be removed from collection 'amazon.aws'
#   version 13.0.0.
#
# The module is NOT krikri-supported (the coverage bar), but real prints
# its task-load-time [DEPRECATION WARNING] exactly like the unsupported
# community.mysql/community.general cases - the mateothegreat.aws_vpc_create
# round diverged on the missing line alone (github issue 865). This mirrors
# proxmox_kvm_redirect_deprecation_test.cr's unsupported-module shape:
# every task when:-gated (an unguarded one would fail the run through
# reachable_unavailable_modules) and the deprecations result entry asserted
# directly against the table helpers rather than through a register:.
#
# The bare spelling is how the role writes it (`ec2_vpc_peer:`), and the
# line echoes the RESOLVED amazon.aws FQCN, never the as-written spelling -
# but amazon.aws is deliberately not in MODULE_SEARCH_COLLECTIONS (its bare
# names resolve through AVAILABLE_PLUGINS' own short-name entries), so the
# bare qualification goes through redirect_deprecation_lookup's own
# explicit amazon.aws prefix.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private TRAILER_LINE = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private DEPRECATION_LINE = "[DEPRECATION WARNING]: amazon.aws.ec2_vpc_peer has been deprecated. " \
                           "ec2_vpc_peer has been renamed to ec2_vpc_peering. Please update your tasks. " \
                           "This feature will be removed from collection 'amazon.aws' version 13.0.0."

# redirect_deprecation_text returns the text WITHOUT the console
# [DEPRECATION WARNING]: prefix (ResultDisplay adds it).
private TABLE_TEXT = DEPRECATION_LINE.sub("[DEPRECATION WARNING]: ", "")

private def run_play(task_lines : Array(String)) : {Bool, String}
  playbook = File.tempname("aws-ec2-vpc-peer-deprecation", ".yml")
  body = [
    "- hosts: localhost",
    "  gather_facts: false",
    "  connection: local",
    "  tasks:",
  ] + task_lines
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "amazon.aws.ec2_vpc_peer redirect deprecation" do
  it "warns at task-load time for the FQCN spelling" do
    success, output = run_play([
      "    - name: peer probe",
      "      amazon.aws.ec2_vpc_peer:",
      "        state: present",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(DEPRECATION_LINE).must_equal(true, output)
    # The stderr lines land before the play banner, like Ansible's
    # task-load-time emission.
    trailer_idx = output.index!(TRAILER_LINE)
    play_idx = output.index!("PLAY [localhost]")
    (trailer_idx < play_idx).must_equal(true, output)
  end

  it "warns with the resolved amazon.aws FQCN for the bare ec2_vpc_peer spelling" do
    # The bare unsupported spelling stays bare in task.module_name
    # (resolve_module_name comes up empty), so this exercises
    # redirect_deprecation_lookup's explicit amazon.aws prefix - real
    # resolves the same spelling to amazon.aws.ec2_vpc_peer and the
    # console line echoes that FQCN, never the bare as-written name.
    success, output = run_play([
      "    - name: bare peer probe",
      "      ec2_vpc_peer:",
      "        state: present",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    output.includes?(DEPRECATION_LINE).must_equal(true, output)
  end

  it "does not warn for the renamed target spelling" do
    success, output = run_play([
      "    - name: target spelling probe",
      "      amazon.aws.ec2_vpc_peering:",
      "        state: present",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(false)
    output.includes?("[DEPRECATION WARNING]").must_equal(false)
  end

  it "carries the redirect msg, collection and removal version in the direct table lookups" do
    Krikri::PlaybookParser.redirect_deprecation_text("amazon.aws.ec2_vpc_peer").must_equal(TABLE_TEXT)
    # The bare spelling must resolve to the same entry through the
    # explicit amazon.aws prefix, despite the module being unimplemented.
    Krikri::PlaybookParser.redirect_deprecation_text("ec2_vpc_peer").must_equal(TABLE_TEXT)
    entry = Krikri::PlaybookParser.redirect_deprecation_result_entry("amazon.aws.ec2_vpc_peer")
    flunk("no deprecations result entry for amazon.aws.ec2_vpc_peer") unless entry
    entry = entry.not_nil!
    # The msg carries NO removal tail; only the console line does.
    entry["msg"].as_s.must_equal(
      "amazon.aws.ec2_vpc_peer has been deprecated. " \
      "ec2_vpc_peer has been renamed to ec2_vpc_peering. Please update your tasks.")
    entry["collection_name"].as_s.must_equal("amazon.aws")
    entry["version"].as_s.must_equal("13.0.0")
    entry["deprecator"]["resolved_name"].as_s.must_equal("amazon.aws")
    entry["deprecator"]["type"].as_s?.must_equal(nil)
  end
end
