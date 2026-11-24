require "../minitest_helper"
require "json"

# Regression tests for a divergence a krikri-playbook-generator
# re-sweep (seed 35) flagged: filesystem's fstype choices-order
# divergence (#53) is unmatchable by design - real builds its choices
# from a Python set, so the order differs on every real process; that
# is masked in the generator (see the generator repo's masks.cr) and
# covered by a membership-only assertion here.

describe "filesystem plugin - fstype choices membership (kpg35)" do
  # Real builds its fstype choices from a Python set
  # (filesystem.py's `fstypes = set(FILESYSTEMS.keys()) - ...`), so the
  # ORDER of the "value of fstype must be one of:" list is random per
  # real process (verified: five consecutive Ansible runs each printed a
  # different order). Only the membership is matchable - the generator
  # masks the list (FSTYPE-SET-ORDER mask); this spec pins membership
  # and the deterministic tail.
  it "rejects a bogus fstype with Ansible's membership and wording" do
    result = PluginSpecHelper.run("filesystem",
      {"dev" => "/tmp/kpg35-no-such-dev", "fstype" => "43"})

    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.must_include("got: 43")
    list_part = msg[/value of fstype must be one of: (.*), got: /, 1]
    list_part.wont_be_nil
    names = list_part.not_nil!.split(", ")
    names.sort!.must_equal(%w[bcachefs btrfs ext2 ext3 ext4 ext4dev f2fs lvm ocfs2 reiserfs swap ufs vfat xfs].sort)
  end
end
