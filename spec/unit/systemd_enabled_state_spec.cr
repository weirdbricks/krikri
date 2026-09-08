require "../spec_helper"
require "../../src/krikri/plugin_helpers/systemd_enabled_state"

# Regression spec for buluma.bind's 0.9.827 regression: `systemctl enable
# bind9` genuinely fails on Ubuntu 22.04 ("Refusing to operate on alias
# name or linked unit file") because bind9.service is a systemd Alias=
# of named.service - but real Ansible's own systemd module never attempts
# the enable call at all here, because its `is-enabled '<name>' -l` check
# gets multi-line output for an alias that never string-matches its own
# exclusion list. See SystemdEnabledState's own comment for the full story.
describe "Krikri::SystemdEnabledState.enabled_from_is_enabled?" do
  it "is false when is-enabled fails outright (disabled/masked/not found)" do
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(1, "").should be_false
  end

  it "is true for a plain single-line 'enabled' state" do
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "enabled\n").should be_true
  end

  it "is true for 'static'/'generated' states, matching real Ansible's own fallthrough" do
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "static\n").should be_true
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "generated\n").should be_true
  end

  it "is false for 'enabled-runtime' and 'indirect' (single-line, exact match)" do
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "enabled-runtime\n").should be_false
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "indirect\n").should be_false
  end

  it "is true for an aliased unit's multi-line -l output, matching real Ansible's accidental fallthrough" do
    # Confirmed live on a real Atlantic Ubuntu 22.04 host:
    # `systemctl is-enabled bind9 -l` for bind9.service (an Alias= of
    # named.service).
    stdout = "alias\n  /etc/systemd/system/multi-user.target.wants/named.service\n  /etc/systemd/system/bind9.service\n"
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, stdout).should be_true
  end

  it "is false for a bare single-line 'alias' with no -l detail (the pre-fix, non-aliased-shape case)" do
    # If some other systemd version/unit ever printed a bare "alias" with
    # no path lines, the exact-match branch should still catch it -
    # this engine's own bug was calling is-enabled WITHOUT -l at all,
    # which always looks like this bare case, not the real multi-line one.
    Krikri::SystemdEnabledState.enabled_from_is_enabled?(0, "alias\n").should be_false
  end
end
