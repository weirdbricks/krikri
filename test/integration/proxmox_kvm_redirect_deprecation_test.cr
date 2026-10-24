require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19's console output for community.general.proxmox_kvm's
# meta/runtime.yml plugin_routing deprecation (community.general moved
# all proxmox content to community.proxmox; removal_version 15.0.0 -
# live-verified against ansible-playbook with the inoxio.proxmox_vms
# role, tmp paths masked):
#
#   [WARNING]: Deprecation warnings can be disabled by setting
#   `deprecation_warnings=False` in ansible.cfg.
#   [DEPRECATION WARNING]: community.general.proxmox_kvm has been
#   deprecated. The proxmox content has been moved to
#   community.proxmox. This feature will be removed from collection
#   'community.general' version 15.0.0.
#
# Same task-load-time shape as the community.mysql redirect deprecation
# (see community_mysql_redirect_deprecation_test.cr): the trailer prints
# once per run before the first line, one [DEPRECATION WARNING] line per
# DISTINCT module per run, before the PLAY banner, also for a
# when:-skipped task.
#
# proxmox_kvm itself is NOT a krikri-supported module (coverage bar):
# only the parse-time stderr deprecation is observable, so every task
# here is when:-gated (an unguarded one would make the run exit 4
# through reachable_unavailable_modules) and the `deprecations` result
# entry is asserted directly against redirect_deprecation_result_entry
# instead of through a register:.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private TRAILER_LINE = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private DEPRECATION_LINE = "[DEPRECATION WARNING]: community.general.proxmox_kvm has been deprecated. " \
                           "The proxmox content has been moved to community.proxmox. " \
                           "This feature will be removed from collection 'community.general' version 15.0.0."

# The play-level `collections:` list is what lets the bare `proxmox_kvm`
# spelling resolve at all - real's loader searches the listed collections
# for unqualified names (a bare name without it refuses the whole
# playbook, live-verified vs 2.19.11) - and it is harmless for the FQCN
# spellings.
private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
  "  collections: [community.general]",
]

# `tasks` are task lines already indented for the play's `tasks:` list.
private def run_play(tasks : Array(String)) : {Bool, String}
  playbook = File.tempname("proxmox-kvm-deprecation", ".yml")
  body = PLAY_HEADER.dup
  body << "  tasks:"
  body.concat(tasks)
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  # One real pipe for both streams (2>&1 in the shell): Process.run with
  # the same IO for output and error copies them through two pipes on
  # separate fibers, so the relative order of the two streams - which the
  # banner-ordering assertion below depends on - flips under load.
  status = Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "community.general.proxmox_kvm deprecation" do
  it "prints the trailer once and one deprecation line per distinct module, before the play banner" do
    success, output = run_play([
      "    - name: first vm",
      "      community.general.proxmox_kvm:",
      "        name: vm1",
      "      when: false",
      "    - name: second vm",
      "      community.general.proxmox_kvm:",
      "        name: vm2",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.scan(TRAILER_LINE).size.must_equal(1)
    # One line for BOTH tasks: Ansible's Display dedups on the message.
    output.scan(DEPRECATION_LINE).size.must_equal(1)
    # The stderr lines land before the play banner, like Ansible's
    # task-load-time emission.
    trailer_idx = output.index!(TRAILER_LINE)
    play_idx = output.index!("PLAY [localhost]")
    (trailer_idx < play_idx).must_equal(true, output)
  end

  it "warns with the resolved FQCN for the bare short-name spelling" do
    success, output = run_play([
      "    - name: bare name",
      "      proxmox_kvm:",
      "        name: vm1",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(true, output)
    # The line echoes the RESOLVED community.general FQCN, never the
    # as-written bare spelling.
    output.includes?(DEPRECATION_LINE).must_equal(true, output)
    output.includes?("proxmox_kvm has been deprecated").must_equal(true)
  end

  it "does not warn for other community.general modules" do
    success, output = run_play([
      "    - name: unrelated module",
      "      community.general.timezone:",
      "      when: false",
    ])
    success.must_equal(true, output)
    output.includes?(TRAILER_LINE).must_equal(false)
    output.includes?("[DEPRECATION WARNING]").must_equal(false)
  end

  it "warns for community.general.proxmox too (engonzal.proxmoxct round)" do
    Krikri::PlaybookParser.redirect_deprecation_text("community.general.proxmox").must_equal(
      "community.general.proxmox has been deprecated. " \
      "The proxmox content has been moved to community.proxmox. " \
      "This feature will be removed from collection 'community.general' version 15.0.0.")
  end

  it "carries the moved-content msg, collection and removal version in the result entry" do
    text = Krikri::PlaybookParser.redirect_deprecation_text("community.general.proxmox_kvm")
    text.must_equal(
      "community.general.proxmox_kvm has been deprecated. " \
      "The proxmox content has been moved to community.proxmox. " \
      "This feature will be removed from collection 'community.general' version 15.0.0.")
    entry = Krikri::PlaybookParser.redirect_deprecation_result_entry("community.general.proxmox_kvm")
    flunk("no deprecations result entry for proxmox_kvm") unless entry
    entry = entry.not_nil!
    # The msg carries NO removal tail; only the console line does.
    entry["msg"].as_s.must_equal(
      "community.general.proxmox_kvm has been deprecated. " \
      "The proxmox content has been moved to community.proxmox.")
    entry["collection_name"].as_s.must_equal("community.general")
    entry["version"].as_s.must_equal("15.0.0")
    entry["deprecator"]["resolved_name"].as_s.must_equal("community.general")
    entry["deprecator"]["type"].as_s?.must_equal(nil)
  end
end
