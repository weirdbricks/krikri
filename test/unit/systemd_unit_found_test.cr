require "../minitest_helper"
require "../../src/krikri/plugin_helpers/systemd_unit_found"

# Regression spec for konstruktoid.hardening's absent-unit tasks
# (`systemd_service: {name: kdump.service, enabled: false, state: stopped,
# masked: true}` on a unit no package installs) on Ubuntu 22.04: real
# ansible-playbook refuses the enabled:/state: steps on a unit that doesn't
# exist, so the task's own failed_when swallows "Could not find the
# requested service" and the task reports `ok`. This engine never asked
# whether the unit existed, masked it (which real also does - systemctl
# masks a never-installed unit happily) and then reported `changed`. See
# SystemdUnitFound's own comment for the real-side source.
describe "Krikri::SystemdUnitFound" do
  it "is found when systemctl show exits 0 and prints a real LoadState" do
    Krikri::SystemdUnitFound.found?(0, "LoadState=loaded\nActiveState=inactive\n", false).must_equal(true)
  end

  it "is found for a masked unit, which is exactly what a mask task creates" do
    Krikri::SystemdUnitFound.found?(0, "LoadState=masked\nActiveState=inactive\n", false).must_equal(true)
  end

  it "is not found for the LoadState=not-found systemd reports for a unit with no file" do
    Krikri::SystemdUnitFound.found?(0, "LoadState=not-found\nActiveState=inactive\n", false).must_equal(false)
  end

  it "is not found when show exits 0 but prints no LoadState at all" do
    # real's `'LoadState' in result['status']` is a dict-membership test:
    # a truncated/empty property dump leaves the key out entirely, which is
    # as missing as an explicit "not-found".
    Krikri::SystemdUnitFound.found?(0, "", false).must_equal(false)
    Krikri::SystemdUnitFound.found?(0, "Id=kdump.service\n", false).must_equal(false)
  end

  it "is not found when systemctl show itself fails" do
    Krikri::SystemdUnitFound.found?(1, "", false).must_equal(false)
  end

  it "is found via a SysV init script even with no usable systemd unit" do
    Krikri::SystemdUnitFound.found?(1, "", true).must_equal(true)
    # ... and the init script alone decides it, systemd's answer ignored.
    Krikri::SystemdUnitFound.found?(0, "LoadState=not-found\n", true).must_equal(true)
  end

  it "picks the first LoadState line out of a full systemctl show dump" do
    show = "Id=kdump.service\nLoadState=masked\nLoadError=not found\nFragmentPath=/etc/systemd/system/kdump.service\n"
    Krikri::SystemdUnitFound.load_state_from_show(show).must_equal("masked")
  end

  it "reads a LoadState whose value carries no trailing newline" do
    Krikri::SystemdUnitFound.load_state_from_show("LoadState=loaded").must_equal("loaded")
  end

  it "returns nil when no LoadState line is present" do
    Krikri::SystemdUnitFound.load_state_from_show("Id=kdump.service\nActiveState=inactive\n").must_equal(nil)
    Krikri::SystemdUnitFound.load_state_from_show("").must_equal(nil)
  end

  it "ignores a property whose value merely looks like a LoadState" do
    # The parser splits on the FIRST '=' and keys strictly on what came
    # before it, matching real's KEY=VALUE dict build.
    Krikri::SystemdUnitFound.load_state_from_show("Description=LoadState=loaded\n").must_equal(nil)
  end
end

describe "Krikri::SystemdUnitFound.missing_service_message" do
  it "matches real's fail_if_missing wording, including the trailing ': host'" do
    # module_utils/service.py: "'Could not find the requested service %s: %s'"
    # with msg='host' passed by systemd_service.py's enabled:/state: blocks -
    # konstruktoid.hardening's failed_when matches on the
    # "Could not find the requested service" substring, but the whole string
    # still has to render identically for any task that does not swallow it.
    Krikri::SystemdUnitFound.missing_service_message("kdump.service").must_equal(
      "Could not find the requested service kdump.service: host")
  end
end
