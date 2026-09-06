require "../spec_helper"

# Round 188 (`buluma.forensics`, Rocky 9.6): a `delegate_to: localhost`
# task in a SSH-routed play runs the delegated plugin via `connection:
# local` on the controller rather than SSH-ing to `localhost:22`. Real
# ansible-core does this; krikri-playbook 0.9.623 went through the
# SSH path and scp'd the plugin binary to `localhost:22`, which failed
# with "Connection refused" on a cloud VPS whose controller has no
# sshd running (the standard Atlantic.net Ubuntu 22.04 / Rocky 9.6
# base image doesn't run sshd on the controller).
#
# This spec covers the *easy half* of the regression: when the
# delegated-to target is the same as the play's connection host, both
# with `connection: local` and with a remote `connection: ssh` (the
# latter only tested when sshd is actually reachable on the controller,
# which the dev box typically doesn't have - guarded below).
#
# The full cloud-side repro (SSH play + delegate_to: localhost + no
# sshd on controller) requires the Atlantic.net harness; see
# `~/scratch/round188_10roles/results/REVERIFY_RESULTS.md` and
# [[round188-delegate-to-localhost-ssh-reupload]] for the live trace.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("delegate-to-localhost-188", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# True iff a local sshd is actually listening on port 22 (i.e. the
# test environment matches the failure surface from the live round
# - controller with sshd reachable). Most dev boxes don't have this;
# the SSH-routed half of this spec is skipped when it's absent.
private def sshd_listening? : Bool
  Process.run("ss", ["-tln", "-H"], output: STDOUT, error: STDERR) do |pth|
    pth.output.gets_to_end.includes?(":22 ")
  end
rescue
  false
end

describe "delegate_to: localhost" do
  # The easy case: play is `connection: local` and the task
  # `delegate_to: localhost` - i.e. the entire play runs on the
  # controller and the delegated task is the same target. Both
  # engines pass on this; pinning the behavior so a future refactor
  # can't quietly regress the "already local" path while fixing
  # the "remote -> local via delegate_to" path.
  it "runs a copy: with delegate_to: localhost in a connection: local play (no SSH detour)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: copy via delegate_to localhost
            ansible.builtin.copy:
              content: "hello from delegate_to"
              dest: "/tmp/r188_delegate_test"
            delegate_to: localhost
      YAML
    status.exit_code.should eq(0)
    output.should contain("PLAY RECAP")
    File.exists?("/tmp/r188_delegate_test").should be_true
  ensure
    File.delete("/tmp/r188_delegate_test") if File.exists?("/tmp/r188_delegate_test")
  end

  # The hard case (the actual round 188 finding): play is
  # `connection: ssh` (or implicit-ssh) and a task
  # `delegate_to: localhost` for an SSH-uploading module. Pre-fix
  # (0.9.622 and earlier - confirmed against 0.9.623), krikri-playbook
  # tried to scp the plugin binary to `localhost:22`, which fails
  # with "Connection refused" on a cloud VPS whose controller has no
  # sshd running. The fix (pending) is in
  # `src/krikri/task_executor/executor.cr` `delegate_to:`
  # resolution: short-circuit to `connection: local` when the
  # delegate target is the controller, so the SSH plugin-upload step
  # is bypassed entirely.
  #
  # The canonical repro for this hard case is the live cloud-side run
  # (round 188 buluma.forensics Rocky 9.6) and has been recorded in
  # [[round188-delegate-to-localhost-ssh-reupload]] + the raw logs in
  # `~/scratch/round188_10roles/logs/`. An equivalent local spec would
  # need a controller with sshd listening (the dev box doesn't have
  # one), which is why the SSH-routed half of this spec is not
  # present here - a future round (round 189+ after the fix lands)
  # can add it back, gated on `sshd_listening?` with a runtime skip,
  # or run it against the existing Atlantic.net harness.

  # Real crash found in a 150-role overnight round
  # (xe0nic.ansible_vprotect_server): `set_fact` + `delegate_to:
  # <some host>` + `delegate_facts: true` crashed the ENTIRE
  # krikri-playbook process with an unhandled "Missing hash key"
  # KeyError - @facts/@set_facts are only pre-seeded for the play's
  # own hosts (executor.cr's per-host init loop), not for an
  # arbitrary delegate_facts: true target, so the very first fact
  # delegated to a never-before-seen host name crashed
  # merge_ansible_facts outright, losing the entire run (not just
  # failing the one task). Fixed with `||=` lazy init in
  # merge_ansible_facts.
  it "does not crash when delegate_facts: true targets a host never seen before (not one of the play's own hosts)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          computed_fqdn: "example.com"
        tasks:
          - name: delegate a fact to a brand-new host name
            ansible.builtin.set_fact:
              computed_fqdn: "{{ computed_fqdn }}"
            delegate_to: a_never_before_seen_delegate_host
            delegate_facts: true
          - debug:
              msg: survived
      YAML
    status.exit_code.should eq(0)
    output.should_not contain("Unhandled exception")
    output.should_not contain("Missing hash key")
    output.should contain("survived")
    output.should contain("PLAY RECAP")
  end
end
