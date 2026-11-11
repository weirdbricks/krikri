require "../minitest_helper"
require "json"
require "../../src/krikri/plugin_helpers/rpm_package"

# Issue #894/#1063 (both split from #889): on a fact-less play
# (gather_facts: false) the dnf action's on-demand pkg_mgr fetch puts
# `ansible_facts: {pkg_mgr: ...}` on the result - failures included. Real
# sets that key BEFORE running the backend module, and
# `result.update(module_result)` only replaces it when the module payload
# ships an `ansible_facts` key of its own: the interpreter-discovery fact
# on the host's very first module execution (which REPLACES the action's -
# #894's captured shape), or nothing once the interpreter and pkg_mgr are
# already known (no fetch runs then and no fact appears at all - #894's
# other captured shape). #894 read those as "failed results never carry
# pkg_mgr" and dropped the fact from failures; issue #1063's 2.21.5
# capture (live-re-verified vs 2.21.6 on AL2023, podman SSH pair) shows
# the fetch + no-discovery case carries {"pkg_mgr": "dnf"} on the FAILED
# "Failed to install some of the specified packages" result exactly as on
# success. The backend-resolution tuple failure is different - real's
# ACTION-level fatal carries the fact there (#768) - but it builds its own
# ansible_facts, which the key check exempts.
#
# The harness stubs the pkg_mgr fact as fetched-on-demand (from_vars false),
# which a vars-pinned PluginSpecHelper.run cannot do: a pinned fact is
# from-vars and skips the attach entirely. The interpreter is pinned so the
# pkg_mgr-shape specs below exercise the configured-interpreter branch -
# real only keeps the action's pkg_mgr fact on the payload when discovery
# never ran (#1063's AL2023 capture ran under a pinned interpreter); the
# auto-interpreter discovery-replacement shape has its own harness below.
private class FinalizeResultHarness
  include Krikri::PluginHelpers::RpmPackage

  def initialize
    @params = {"use_backend" => "auto"} of String => String
    @vars = {"ansible_python_interpreter" => JSON::Any.new("/usr/bin/python3")} of String => JSON::Any
    @pkg_mgr_fact = "dnf"
    @pkg_mgr_fact_from_vars = false
  end

  protected def remote_exec(command : String, timeout : Int32? = nil, force_shell : Bool = false) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
    {exit_code: 0, stdout: "fact:dnf", stderr: ""}
  end

  def pkg_manager_binary : String
    "dnf"
  end
end

# Issue #1113 (same signature as #894): on a fact-less host with the
# default (unset/auto) interpreter, real's dnf action instance runs
# interpreter discovery on its on-demand setup fetch and then stamps
# discovered_interpreter_python onto the backend module's payload - which
# REPLACES the action's pkg_mgr fact on the wire. The discovery probe is
# stubbed so the asserted path is deterministic.
private class DiscoveryHarness < FinalizeResultHarness
  def initialize(vars : Hash(String, JSON::Any) = {} of String => JSON::Any)
    super()
    @vars = vars
  end

  protected def discovered_interpreter_path : String
    "/usr/bin/python3.12"
  end
end

describe "dnf: fetched pkg_mgr fact vs interpreter discovery on the payload (issue 1113)" do
  it "replaces the fetched pkg_mgr fact with the discovery fact on a failed result when discovery runs" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: allow_dwongrade."
    )
    out = DiscoveryHarness.new.finalize_result(failed)
    out.extra["ansible_facts"].as_h.size.must_equal(1)
    out.extra["ansible_facts"].as_h["discovered_interpreter_python"].as_s
      .must_equal("/usr/bin/python3.12")
    out.extra["ansible_facts"].as_h["pkg_mgr"]?.must_be_nil
  end

  it "replaces the fetched pkg_mgr fact with the discovery fact on a successful result too" do
    ok = Krikri::PluginResult.new(
      changed: false,
      failed: false,
      msg: "Nothing to do",
      include_empty_msg: true,
      key_order: ["msg", "changed", "results", "rc", "failed"]
    )
    out = DiscoveryHarness.new.finalize_result(ok)
    out.extra["ansible_facts"].as_h["discovered_interpreter_python"].as_s
      .must_equal("/usr/bin/python3.12")
    out.extra["ansible_facts"].as_h["pkg_mgr"]?.must_be_nil
  end

  it "keeps the fetched pkg_mgr fact when the interpreter is configured" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: allow_dwongrade."
    )
    pinned = DiscoveryHarness.new({"ansible_python_interpreter" => JSON::Any.new("/usr/bin/python3")})
    out = pinned.finalize_result(failed)
    out.extra["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("dnf")
    out.extra["ansible_facts"].as_h["discovered_interpreter_python"]?.must_be_nil
  end

  it "keeps the fetched pkg_mgr fact when discovery already ran earlier in the run" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: allow_dwongrade."
    )
    discovered = DiscoveryHarness.new({"discovered_interpreter_python" => JSON::Any.new("/usr/bin/python3.10")})
    out = discovered.finalize_result(failed)
    out.extra["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("dnf")
    out.extra["ansible_facts"].as_h["discovered_interpreter_python"]?.must_be_nil
  end
end

describe "dnf: fetched pkg_mgr fact on the result (issue 894)" do
  it "keeps the fetched pkg_mgr fact on a successful result" do
    ok = Krikri::PluginResult.new(
      changed: false,
      failed: false,
      msg: "Nothing to do",
      include_empty_msg: true,
      key_order: ["msg", "changed", "results", "rc", "failed"]
    )
    out = FinalizeResultHarness.new.finalize_result(ok)
    out.extra["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("dnf")
    out.key_order.try(&.first?).must_equal("ansible_facts")
  end

  it "attaches the fetched pkg_mgr fact to a failed result with no facts of its own" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: bgufix."
    )
    out = FinalizeResultHarness.new.finalize_result(failed)
    out.extra["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("dnf")
  end

  # Issue #1063: the "Failed to install some of the specified packages"
  # failure (missing spec in a name list) carries the fetched fact in real
  # 2.21.5/2.21.6 alongside its failures/results - krikri's failed result
  # kept them but dropped the fact.
  it "carries the fetched pkg_mgr fact on a failed install with failures and results (issue 1063)" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Failed to install some of the specified packages",
      include_empty_msg: true,
      failures: ["No package no-such-package-xyz available."],
      results: ["Installed: tree-1.8.0-6.amzn2023.0.2.x86_64"],
      rc: 1,
      key_order: Krikri::PluginHelpers::RpmPackage::DNF_FAILURE_ORDER
    )
    out = FinalizeResultHarness.new.finalize_result(failed)
    out.extra["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("dnf")
    out.extra["failures"].as_a.map(&.as_s).must_equal(["No package no-such-package-xyz available."])
    out.extra["results"].as_a.map(&.as_s).must_equal(["Installed: tree-1.8.0-6.amzn2023.0.2.x86_64"])
    out.key_order.try(&.first?).must_equal("ansible_facts")
  end

  it "leaves a failed result's own ansible_facts untouched" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: bgufix."
    )
    failed.extra["ansible_facts"] = JSON::Any.new(
      {"discovered_interpreter_python" => JSON::Any.new("/usr/bin/python3")}
    )
    out = FinalizeResultHarness.new.finalize_result(failed)
    out.extra["ansible_facts"].as_h["pkg_mgr"]?.must_be_nil
    out.extra["ansible_facts"].as_h["discovered_interpreter_python"].as_s
      .must_equal("/usr/bin/python3")
  end
end
