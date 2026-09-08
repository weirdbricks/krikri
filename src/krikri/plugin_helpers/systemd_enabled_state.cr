module Krikri
  # Pure decision logic for the systemd plugin's own boot-enabled check,
  # factored out into its own file (rather than a private method on
  # SystemdPlugin) so a spec can require it directly without triggering
  # plugins/systemd.cr's own bottom-of-file STDIN entry point - same
  # reason AptLockRetry lives in its own file (see there).
  module SystemdEnabledState
    # Real Ansible's own systemd module runs `is-enabled '<name>' -l`
    # (long/no-truncate) and treats the result as enabled UNLESS its
    # (rstripped, but otherwise unparsed) stdout is EXACTLY one of
    # "enabled-runtime", "indirect", "alias" - anything else with rc=0
    # (including plain "enabled", "static", "generated", ...) counts as
    # already-enabled. This looks like it was meant to single out those
    # three states specifically, but `-l` makes an ALIASED unit's
    # is-enabled output multi-line ("alias\n  /path/to/real.service\n
    # /path/to/alias.service\n"), which never equals the bare string
    # "alias" - so real Ansible's own check silently falls through to
    # "already enabled" for an alias and never calls `enable` on it at
    # all. Found via buluma.bind on Ubuntu 22.04: `bind9.service` is a
    # systemd Alias= of `named.service`, and `systemctl enable bind9`
    # genuinely refuses ("Refusing to operate on alias name or linked
    # unit file") - this engine's own single-line `is-enabled` (no `-l`)
    # correctly saw "alias" and tried to enable anyway, exactly the
    # refused command, while real Ansible's `-l`-induced multi-line
    # output accidentally skipped the whole enable step. Replicating the
    # exact (if quirky) real-Ansible string comparison, `-l` and all, so
    # both engines make the identical enable/no-op decision on an
    # aliased unit. Live-reverified on a real Atlantic Ubuntu 22.04 host.
    def self.enabled_from_is_enabled?(exit_code : Int32, stdout : String) : Bool
      return false unless exit_code == 0
      !{"enabled-runtime", "indirect", "alias"}.includes?(stdout.rstrip)
    end
  end
end
