require "../minitest_helper"
require "../../src/krikri/conditional_evaluator"

# A chain whose string-producing filter renders the TEXT "false"/"true"/
# "null" must stay a str, not be re-parsed into a JSON boolean/None.
# stafwag.proxy_env gates its /etc/profile and apt work on
# `proxy.etc_profile_proxy | default(false) | lower not in ['false']`;
# with the role's own defaults (proxy: {}) the value is Bool false, so
# `| lower` yields the str "false" and ansible skips every one of those
# tasks. Re-typing the render back into Bool false made the membership
# check compare Bool false against the str element 'false', answer
# `not in` true, and run tasks (and whole include_tasks files) ansible
# skips - the live divergence in round29916782 (issue #1518).
# Answer shapes verified against ansible-core 2.19 before encoding here.
describe "Krikri::ConditionalEvaluator (conditional_lower_string_result_test.cr)" do
  private def vars
    {
      "proxy" => JSON.parse(%({"etc_profile_proxy": false, "pkg_mgr_proxy": true})),
    }
  end

  it "treats a lowered bool as the string it printed, not a bool" do
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.etc_profile_proxy | default(false) | lower in ['false']", vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.etc_profile_proxy | default(false) | lower not in ['false']", vars).must_equal(false)
    Krikri::ConditionalEvaluator.evaluate(
      "(proxy.etc_profile_proxy | lower) == 'false'", vars).must_equal(true)
  end

  it "does the same for a true value and a to_json render" do
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.pkg_mgr_proxy | default(false) | lower in ['true']", vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.pkg_mgr_proxy | lower not in ['false']", vars).must_equal(true)
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.etc_profile_proxy | to_json == 'false'", vars).must_equal(true)
  end

  it "still answers a real boolean chain result as a bool" do
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.etc_profile_proxy | bool", vars).must_equal(false)
    Krikri::ConditionalEvaluator.evaluate(
      "proxy.pkg_mgr_proxy | bool == true", vars).must_equal(true)
  end
end
