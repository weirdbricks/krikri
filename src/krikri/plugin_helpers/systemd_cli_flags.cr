module Krikri
  # Pure decision logic for the systemd plugin's two boolean systemctl
  # CLI flags, factored into its own file (like SystemdEnabledState) so a
  # spec can require it directly without triggering plugins/systemd.cr's
  # bottom-of-file STDIN entry point.
  #
  # - `force` (bool, no default): real Ansible's own systemd module
  #   prepends `--force` to its systemctl invocation when set - here
  #   applied to the enable/disable/mask/unmask calls, the commands where
  #   it actually changes behavior.
  # - `no_block` (bool, default false): `--no-block` on the state-changing
  #   calls (start/stop/restart/reload) so systemctl returns immediately
  #   instead of waiting for the unit to reach the target state.
  module SystemdCliFlags
    # Mirrors BasePlugin#true?'s BOOLEANS_TRUE list (y/yes/on/1/true/t) -
    # kept in sync by hand because a pure module-level helper can't reach
    # that protected instance method.
    private TRUTHY = ["true", "yes", "1", "on", "y", "t"]

    def self.force_flag(force : String?) : String
      given?(force) ? " --force" : ""
    end

    def self.no_block_flag(no_block : String?) : String
      given?(no_block) ? " --no-block" : ""
    end

    private def self.given?(value : String?) : Bool
      value.try { |v| TRUTHY.includes?(v.downcase) } == true
    end
  end
end
