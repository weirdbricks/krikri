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
    # ssh invocation; --scp-extra-args likewise to every `scp` one.
    #
    # KNOWN_MISSING.md used to record --scp-extra-args as "accepted and
    # stored, but nothing to attach to - this engine moves files over
    # ssh plus a piped stream rather than shelling out to scp". That was
    # wrong on its own facts: SSHManager#upload_file/#download_file are
    # real `scp` invocations, and PluginManager falls back to `scp` for
    # the plugin-binary push whenever rsync is unavailable on the
    # target. So the flag now takes effect on exactly those, the way
    # real Ansible applies it to its own scp transfers.
    #
    # --sftp-extra-args stays accepted-and-inert, and that one IS
    # correct by construction: nothing here ever invokes sftp, so, as
    # with real Ansible under a non-sftp transfer method, there is no
    # sftp command line for it to extend.
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
      split_args({ssh_common_args, ssh_extra_args})
    end

    # The same for `scp` invocations: real Ansible applies
    # --ssh-common-args to scp too (it is the COMMON set), plus
    # --scp-extra-args on top - only --ssh-extra-args is ssh-only.
    def self.extra_scp_args : Array(String)
      split_args({ssh_common_args, scp_extra_args})
    end

    private def self.split_args(sources) : Array(String)
      args = [] of String
      sources.each do |raw|
        next unless raw
        args.concat(raw.split(/\s+/).reject(&.empty?))
      end
      args
    end
  end
end
