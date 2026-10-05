module Krikri
  # Real Ansible's own systemd module decides ONCE, before it acts on the
  # unit, whether that unit exists at all (`found`), and then refuses to
  # enable/disable or start/stop something it could not find - see
  # the real module's fail_if_missing, called as
  # fail_if_missing(module, found, unit, msg='host') at the top of both the
  # `enabled:` and `state:` blocks of systemd_service.py.
  #
  # Its is_systemd test is deliberately narrow: `systemctl show <unit>` must
  # have exited 0 AND printed a LoadState property AND that LoadState must
  # not be "not-found". A unit that is masked still has a LoadState of
  # "masked" and therefore counts as FOUND - masking is a real operation
  # real performs on a not-yet-installed unit, so "not installed" must not
  # be confused with "installed but hidden". is_initd is a separate,
  # equally sufficient signal: real's sysv_exists() just checks for the
  # init script under /etc/init.d.
  #
  # Factored into its own file (like SystemdEnabledState next door) so a
  # spec can require the decision logic directly without triggering
  # plugins/systemd.cr's bottom-of-file STDIN entry point.
  module SystemdUnitFound
    # `systemctl show <unit>` (the same probe real runs, reused here rather
    # than a second round trip) plus the SysV init-script presence real's
    # sysv_exists() checks. Real's remaining fallbacks for a `show` that
    # exits non-zero (the "Failed to parse bus message" workaround, then
    # is-enabled/list-unit-files) are not replicated: nothing on this path
    # has ever consulted them, so a `show` that fails for anything other
    # than the no-bus case leaves the unit reported as missing.
    def self.found?(show_exit_code : Int32, show_stdout : String, init_script_present : Bool) : Bool
      return true if init_script_present
      return false unless show_exit_code == 0
      load_state = load_state_from_show(show_stdout)
      return false if load_state.nil?
      load_state != "not-found"
    end

    # `systemctl show` prints one `KEY=VALUE` line per unit property; real
    # parses the whole thing into result['status'] and reads LoadState out
    # of that dict. Only the first LoadState line is looked at, matching the
    # dict-building parse (a later duplicate key would overwrite the earlier
    # one, but systemctl never emits one).
    def self.load_state_from_show(show_stdout : String) : String?
      show_stdout.each_line do |line|
        key, sep, value = line.partition('=')
        return value.strip if sep == "=" && key == "LoadState"
      end
      nil
    end

    # fail_if_missing's exact wording (the real module:117-118) -
    # note the trailing ": host" (real passes msg='host' from systemd's
    # enabled:/state: blocks) and no trailing period.
    def self.missing_service_message(unit : String) : String
      "Could not find the requested service #{unit}: host"
    end
  end
end
