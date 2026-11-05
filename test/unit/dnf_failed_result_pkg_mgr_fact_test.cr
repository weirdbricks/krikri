require "../minitest_helper"
require "json"
require "../../src/krikri/plugin_helpers/rpm_package"

# Issue #894 (split from #889): on a fact-less play (gather_facts: false) the
# dnf action's on-demand pkg_mgr fetch used to glue
# `ansible_facts: {pkg_mgr: ...}` onto EVERY result, failures included. Real
# ansible's failed module results never carry that fact: the module's own
# failure payload - the interpreter-discovery fact on the first module
# execution, nothing once discovery has already run - replaces whatever the
# action attached (live-verified vs ansible-core 2.15.13 on Rocky 9, podman
# SSH pair: the failed "Unsupported parameters" result shows
# {"discovered_interpreter_python": "/usr/bin/python3"} or no ansible_facts
# key at all, never pkg_mgr). The backend-resolution tuple failure is
# different - real's ACTION-level fatal does carry the fact there (#768) -
# but it builds its own ansible_facts and never reaches this path.
#
# The harness stubs the pkg_mgr fact as fetched-on-demand (from_vars false),
# which a vars-pinned PluginSpecHelper.run cannot do: a pinned fact is
# from-vars and skips the attach entirely.
private class FinalizeResultHarness
  include Krikri::PluginHelpers::RpmPackage

  def initialize
    @params = {"use_backend" => "auto"} of String => String
    @vars = Hash(String, JSON::Any).new
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

  it "does not attach the fetched pkg_mgr fact to a failed result" do
    failed = Krikri::PluginResult.new(
      changed: false,
      failed: true,
      msg: "Unsupported parameters for (ansible.legacy.dnf) module: bgufix."
    )
    out = FinalizeResultHarness.new.finalize_result(failed)
    out.extra.has_key?("ansible_facts").must_equal(false)
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
