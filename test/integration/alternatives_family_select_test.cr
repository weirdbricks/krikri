require "../minitest_helper"

# community.general.alternatives parity for the `family:`-only shape and
# for update-alternatives' own failures (live-verified against
# ansible-playbook 2.19.11 on this host, 2026-10-01 - krikri-playbook
# generator round 33 re-sweep, cases #180/#187):
#
#   - with only `family:` given, real's self.path is None, so the
#     install() branch is skipped entirely and the gate is
#     `not (is_same_path or is_same_family)` with is_same_path always
#     false - real therefore DOES run `update-alternatives --set <name>
#     <family>`. This plugin used to require a `path:` for the select,
#     silently doing nothing (reported ok: instead of running it);
#   - every update-alternatives call real makes uses run_command(
#     check_rc=True), so a rejected command is basic.py's own failure:
#     msg is the bare rstripped stderr, and cmd/rc/stdout/stderr plus
#     the controller-derived *_lines ride along. `cmd` names the
#     absolute path get_bin_path resolved.

describe "alternatives family-only selection" do
  it "runs --set with the family when no path is given, and reports the command's failure" do
    result = PluginSpecHelper.run("alternatives", {
      "family" => "krikri-spec-family",
      "name"   => "krikri-spec-family-alt",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    # update-alternatives rejects a non-absolute path itself.
    result["msg"].as_s.must_equal(
      "update-alternatives: error: alternative path is not absolute as it should be: krikri-spec-family")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_include("update-alternatives --set krikri-spec-family-alt krikri-spec-family")
    result["stdout"].as_s.must_equal("")
    result["stdout_lines"].as_a.must_be_empty
    result["stderr_lines"].as_a.map(&.as_s).must_equal([
      "update-alternatives: error: alternative path is not absolute as it should be: krikri-spec-family",
    ])
  end

  it "never installs when only family is given, even with a link" do
    result = PluginSpecHelper.run("alternatives", {
      "family" => "krikri-spec-family2",
      "name"   => "krikri-spec-family-alt2",
      "link"   => "/tmp/krikri-spec-family-link",
      "state"  => "present",
    })

    # state: present skips the select branch, and the install branch is
    # gated on path in real too - so nothing runs at all.
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    File.exists?("/tmp/krikri-spec-family-link").must_equal(false)
  end
end
