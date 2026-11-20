require "./ansible_config"

# The one-time "[WARNING]: Deprecation warnings can be disabled by
# setting `deprecation_warnings=False` in ansible.cfg." hint ansible-core's
# Display prints ahead of the FIRST deprecation of any kind in a run
# (Display._deprecated's warning() call is itself deduped process-wide) -
# shared by every deprecation emitter (parse-time action-mapping warnings,
# the executor's conditional-delimiter warnings) so the hint appears
# exactly once across all kinds, not once per emitter.
module Krikri::DeprecationHint
  @@hint_seen = false
  @@hint_mutex = Mutex.new

  # Whether a deprecation may print at all. ansible's Display.deprecated
  # returns before its hint AND its block while DEPRECATION_WARNINGS is
  # false, but the deprecated feature still runs and its entry still rides
  # the task result - so emitters gate only their console write with this,
  # never the capture that carries the result's `deprecations` entry
  # (live-verified vs 2.21.6, issue #1660).
  def self.enabled? : Bool
    Krikri::AnsibleConfig.deprecation_warnings_enabled?
  end

  # Claims the process-wide once-flag for the caller that gets to print the
  # hint. Separate from print_hint_once so emitters with their own output
  # style (the executor's colorized display path) share this single flag
  # instead of keeping a second one - two flags let a run that warns both at
  # parse time and in the executor print the hint twice, where ansible's
  # Display dedups it process-wide (issue #1149).
  def self.claim : Bool
    return false unless enabled?
    @@hint_mutex.synchronize do
      return false if @@hint_seen
      @@hint_seen = true
      true
    end
  end

  def self.print_hint_once : Nil
    STDERR.puts "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg." if claim
  end
end
