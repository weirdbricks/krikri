require "../spec_helper"
require "../../src/krikri/ssh_manager"

# Real bug found benchmarking buluma.netdata (round 163 regression
# check): Krikri::SSHManager's per-command execution timeout was a
# hardcoded 300s (5 minutes) default shared by #exec/#exec_script/
# #daemon_send. Real Ansible has no default command-duration limit at
# all - a foreground task runs until it completes, however long that
# takes. netdata's own installer genuinely compiles from source and
# took a confirmed 1536s (~25.6 minutes) against real ansible-playbook;
# crystal's identical task was killed at exactly 300s despite the
# remote command still actively running and eventually succeeding.
# This spec is a deliberately blunt guard against the default silently
# regressing back down to something too short for realistic real-world
# tasks (compiles, large package installs) - not a behavioral test of
# the timeout mechanism itself (that needs a real SSH round trip,
# already covered qualitatively by plugin_daemon_spec.cr's own local-
# pipe stand-in for the wire protocol).
describe Krikri::SSHManager do
  it "defaults the per-command execution timeout to at least 30 minutes" do
    Krikri::SSHManager::DEFAULT_EXEC_TIMEOUT_SECONDS.should be >= 1800
  end
end
