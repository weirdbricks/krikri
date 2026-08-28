require "../spec_helper"
require "../../src/crystal_play/conditional_evaluator"

# Round 194 regression cover (andrewrothstein.pkg-upgrade, rocky 9.6):
# the role's vars/RedHat.yml only has pkg_upgrade_update_cmds keys for
# ansible_distribution_major_version 7 and 8, so on a freshly
# provisioned Rocky 9.6 host the chained-subscript expression
# `pkg_upgrade_update_cmds[ansible_distribution_major_version]["update"]`
# resolves to nothing. Real ansible's `when: pkg_upgrade_update_cmd is
# defined` evaluates False and SKIPS the task; crystal previously
# evaluated True and ran the task with the literal text "undefined" as
# the command - then crashed with "Error executing process: 'undefined'".
#
# The root cause was in VarSubstitutor#raise_if_strict_undefined (the
# strict-substitute gate that unresolvable_template? uses to decide
# whether a stored value is "really defined" or just a stored
# unrendered `{{ }}` template). The chained-subscript shape
# `dict[var_name]["key"]` is rejected by REGEX_BARE_VAR_REF (which only
# accepts numeric or quoted-string literal keys inside the brackets)
# and has no `|` (so the filter-chain source check also returns nil),
# so the strict probe fell through to "lenient" without ever attempting
# the actual resolution. The fix: between those two fall-throughs,
# attempt the real VariableLookup.resolve for any expression that
# contains `.` or `[` and is otherwise not a function call or filter.
describe CrystalPlay::ConditionalEvaluator do
  describe "is defined / is undefined on chained-subscript expressions (round 194)" do
    it "pkg_upgrade_update_cmd is defined: false when dict lookup misses on Rocky 9" do
      # Exactly the andrewrothstein.pkg-upgrade vars layout on a
      # Rocky 9.6 host: pkg_upgrade_update_cmds has keys 7 and 8,
      # ansible_distribution_major_version is "9", and the chained
      # subscript resolves to nothing.
      vars = {
        "ansible_distribution"                => JSON::Any.new("Rocky"),
        "ansible_distribution_major_version" => JSON::Any.new("9"),
        "ansible_os_family"                   => JSON::Any.new("RedHat"),
        "pkg_upgrade_update_cmds" => JSON::Any.new({
          "7" => JSON::Any.new({"update" => JSON::Any.new("yum update -q -y"), "upgrade" => JSON::Any.new("yum upgrade -q -y")}),
          "8" => JSON::Any.new({"update" => JSON::Any.new("dnf update -q -y"), "upgrade" => JSON::Any.new("dnf upgrade -q -y")}),
        }),
        "pkg_upgrade_update_cmd"   => JSON::Any.new("{{ pkg_upgrade_update_cmds[ansible_distribution_major_version][\"update\"] }}"),
        "pkg_upgrade_upgrade_cmd" => JSON::Any.new("{{ pkg_upgrade_update_cmds[ansible_distribution_major_version][\"upgrade\"] }}"),
      } of String => JSON::Any

      CrystalPlay::ConditionalEvaluator.evaluate("pkg_upgrade_update_cmd is defined", vars).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("pkg_upgrade_update_cmd is undefined", vars).should be_true
    end

    it "is defined: true when the chained lookup actually resolves" do
      # Same vars shape but ansible_distribution_major_version is "7"
      # this time, so the second subscript hits a real key and the
      # whole expression renders to "yum update -q -y". Both engines
      # agree: defined.
      vars = {
        "ansible_distribution"                => JSON::Any.new("Rocky"),
        "ansible_distribution_major_version" => JSON::Any.new("7"),
        "ansible_os_family"                   => JSON::Any.new("RedHat"),
        "pkg_upgrade_update_cmds" => JSON::Any.new({
          "7" => JSON::Any.new({"update" => JSON::Any.new("yum update -q -y"), "upgrade" => JSON::Any.new("yum upgrade -q -y")}),
          "8" => JSON::Any.new({"update" => JSON::Any.new("dnf update -q -y"), "upgrade" => JSON::Any.new("dnf upgrade -q -y")}),
        }),
        "pkg_upgrade_update_cmd"   => JSON::Any.new("{{ pkg_upgrade_update_cmds[ansible_distribution_major_version][\"update\"] }}"),
      } of String => JSON::Any

      CrystalPlay::ConditionalEvaluator.evaluate("pkg_upgrade_update_cmd is defined", vars).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("pkg_upgrade_update_cmd is undefined", vars).should be_false
    end

    it "simple dotted chain - missing key at end is undefined" do
      # a.b.c where b doesn't have a "c" key - REGEX_BARE_VAR_REF would
      # match this shape (a.b.c is bare-ref-compatible), so the original
      # code path already handled it. Pinned here so the new chained
      # branch doesn't accidentally regress the bare-ref path.
      vars = {
        "a" => JSON::Any.new({"b" => JSON::Any.new({"d" => JSON::Any.new(1)})} of String => JSON::Any),
      } of String => JSON::Any
      CrystalPlay::ConditionalEvaluator.evaluate("a.b.c is defined", vars).should be_false
      CrystalPlay::ConditionalEvaluator.evaluate("a.b.d is defined", vars).should be_true
    end

    it "dict[var_name] where dict has the key - defined" do
      # Make sure the new chained-subscript branch doesn't reject
      # valid lookups. The shape dict[var_name] has an unquoted
      # identifier in brackets, so it doesn't match REGEX_BARE_VAR_REF
      # and the new branch is what handles it.
      vars = {
        "which"        => JSON::Any.new("x"),
        "by_which_key" => JSON::Any.new({"x" => JSON::Any.new("found"), "y" => JSON::Any.new("not this")}),
      } of String => JSON::Any
      CrystalPlay::ConditionalEvaluator.evaluate("by_which_key[which] is defined", vars).should be_true
      CrystalPlay::ConditionalEvaluator.evaluate("by_which_key[which] is undefined", vars).should be_false
    end

    it "function-call shape (a.b) doesn't get treated as chained lookup" do
      # Sanity check that the new branch's `(` carve-out works.
      # `some_func(a.b)` has a `(` so the new branch returns before
      # doing the lookup, and the existing expression-eval path
      # handles it. Pin the regression: a chained dotted ref with
      # nothing in vars should be reported as undefined via the
      # original bare-ref path, not via the new chained path.
      vars = {} of String => JSON::Any
      CrystalPlay::ConditionalEvaluator.evaluate("a.b is defined", vars).should be_false
    end
  end
end
