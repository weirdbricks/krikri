# #1703 - a host booked UNREACHABLE that only delegates still unwinds rescue:/always:

- Issue: https://github.com/weirdbricks/krikri/issues/1703
- Repro: the issue's block: shape with both unwind sections, all three
  tasks delegating to localhost, plus a trailing `ping:` (which is what
  makes the eager pre-upload pass dial at all). `always-fail` stands in for
  the dead ssh endpoint, so no real host is involved.

**What diverged.** krikri's eager pass books the host UNREACHABLE before the
body runs, but the body itself never dials it - the delegated `fail:` fails
on localhost, which ansible reports (`fatal: [target -> localhost]:
FAILED!`) and unwinds through `rescue:` and `always:`. krikri skipped both,
because the unwind decision asked "is the host in the known-unreachable set"
rather than "did the body really lose it here" - and the trailing `ping:` is
the task that finally fails UNREACHABLE. ansible's recap: `ok=2 changed=0
unreachable=1 rescued=1`.

**Fix.** `execute_block_multi` unwinds only the hosts whose own unreachable
count went up during the body, so a pre-upload booking on a play that only
delegates does not cancel its `rescue:`/`always:`.
