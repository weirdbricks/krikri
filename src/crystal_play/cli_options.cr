module CrystalPlay
  # Run-scoped overrides that come from the command line rather than from
  # the playbook or inventory. Real ansible-playbook exposes most of
  # these as flags whose effect is exactly "set this connection variable
  # for every host", which is how they are applied here too (see
  # #apply_host_overrides in crystal-play.cr) - the few that change how
  # ssh itself is invoked are read directly by SSHManager.
  #
  # A module-level singleton rather than threaded parameters because the
  # ssh-invocation sites are spread across SSHManager and are otherwise
  # unaware of the CLI.
  module CliOptions
    # -T/--timeout: ssh ConnectTimeout, in seconds. Real Ansible's
    # default is 10, which is what this engine hardcoded before.
    class_property timeout : Int32 = 10

    # --ssh-common-args / --ssh-extra-args, appended verbatim to every
    # ssh invocation. (--scp-extra-args/--sftp-extra-args are accepted
    # and stored, but this engine moves files over `ssh` + a piped
    # stream rather than scp/sftp, so they have nothing to attach to -
    # see KNOWN_MISSING.md.)
    class_property ssh_common_args : String? = nil
    class_property ssh_extra_args : String? = nil
    class_property scp_extra_args : String? = nil
    class_property sftp_extra_args : String? = nil

    # --step: prompt before each task.
    class_property? step : Bool = false

    # Extra ssh arguments contributed by --ssh-common-args and
    # --ssh-extra-args, split the way a shell would (real Ansible passes
    # these through to ssh as a raw argument string).
    def self.extra_ssh_args : Array(String)
      args = [] of String
      {ssh_common_args, ssh_extra_args}.each do |raw|
        next unless raw
        args.concat(raw.split(/\s+/).reject(&.empty?))
      end
      args
    end
  end
end
