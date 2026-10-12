# The one-time "[WARNING]: Deprecation warnings can be disabled by
# setting `deprecation_warnings=False` in ansible.cfg." hint ansible-core's
# Display prints ahead of the FIRST deprecation of any kind in a run
# (Display._deprecated's warning() call is itself deduped process-wide) -
# shared by every deprecation emitter (parse-time action-mapping warnings,
# the executor's conditional-delimiter warnings) so the hint appears
# exactly once across all kinds, not once per emitter.
module Krikri::DeprecationHint
  @@hint_seen = false

  def self.print_hint_once : Nil
    return if @@hint_seen
    @@hint_seen = true
    STDERR.puts "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."
  end
end
