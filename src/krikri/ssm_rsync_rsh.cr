require "digest/sha256"
require "json"
require "random/secure"
require "./shell"
require "./connection_settings"
require "./remote_staging"
require "./ssm_settings"
require "./ssm_registry"
require "./ssm_transport"

module Krikri
  # The remote-shell half of `synchronize:` over an AWS SSM host.
  #
  # An SSH target needs no controller-side help: rsync builds its own
  # `ssh host rsync --server ...` command. An SSM host has no ssh path, so
  # the action plugin points rsync's `--rsh` at this binary's hidden
  # `__ssm_rsync_rsh` mode instead. rsync runs unchanged on the controller
  # (it still resolves rsync, builds the flag argv, computes the change
  # list and produces the usual `cmd`/stdout), and this mode is spawned in
  # place of ssh: it opens the host's SSM session, uploads a small runner
  # script and moves rsync's protocol bytes through the session's (raw) pty.
  #
  # rsync's server needs real pipes: through a raw pty it stalls after its
  # startup exchange. The uploaded krikri-ssm-pipe bridge (see
  # SsmPipeBridge) runs on the target, spawns the server with pipes and pumps
  # both directions, so the protocol is a plain byte stream again.
  #
  # Connection options reach the child through {ENV_SETTINGS} because rsync
  # spawns the rsh with no extra arguments of ours; the parent puts the blob
  # in rsync's environment, so the child inherits it and nothing secret
  # reaches a command line or a log. The child owns its session (the parent
  # is blocked in rsync), which also keeps the protocol's strict
  # request/response ordering out of the shared task session.
  module SsmRsyncRsh
    extend self

    # argv[0] dispatch string for the hidden mode.
    ARGV_DISPATCH = "__ssm_rsync_rsh"
    ENV_SETTINGS  = "KRIKRI_SSM_RSYNC_SETTINGS"
    ENV_TIMEOUT   = "KRIKRI_SSM_RSYNC_TIMEOUT"
    NAME          = "krikri-ssm-rsync"

    # The `--rsh=` value rsync should use. rsync parses this string itself
    # (split_cmd), then appends the host label and the server arguments.
    # *executable_for_spec* is a test seam (like
    # SSHManager.sshpass_available_for_spec): specs point rsync at a script
    # that stands in for the SSM transport without a gateway.
    class_property executable_for_spec : String? = nil
    # The target-side bridge (krikri-ssm-pipe) location; specs set it when
    # the binary is not next to the test runner.
    class_property bridge_for_spec : String? = nil

    def rsh_command : String
      executable = executable_for_spec || Process.executable_path || "krikri-playbook"
      "#{Shell.quote_arg(executable)} #{ARGV_DISPATCH}"
    end

    # The environment overlay for the controller-side rsync process. The
    # JSON blob carries the resolved SsmSettings; credentials the inventory
    # supplied statically ride along, otherwise the child resolves the
    # standard AWS chain from the environment it inherits.
    def env_for(settings : SsmSettings, timeout : Int32? = nil) : Hash(String, String)
      payload = JSON.build do |json|
        json.object do
          json.field "target", settings.target
          json.field "region", settings.region
          json.field "profile", settings.profile if settings.profile
          json.field "document", settings.document if settings.document
          json.field "endpoint_url", settings.endpoint_url if settings.endpoint_url
          json.field "access_key_id", settings.access_key_id if settings.access_key_id
          json.field "secret_access_key", settings.secret_access_key if settings.secret_access_key
          json.field "session_token", settings.session_token if settings.session_token
          json.field "shell_type", settings.shell_type if settings.shell_type
          json.field "windows_vars", settings.windows_vars?
          json.field "timeout", settings.timeout
          json.field "retries", settings.retries
        end
      end
      env = {ENV_SETTINGS => payload}
      # rsync treats 0/negative rsync_timeout as "no timeout"; the pipe's
      # idle cap must not receive either or it would kill the first transfer.
      env[ENV_TIMEOUT] = timeout.to_s if timeout && timeout > 0
      env
    end

    # The target-side bridge: a small Crystal binary that gives the remote
    # command real pipes (the pty alone stalls rsync's binary protocol after
    # its startup exchange). It ships next to krikri-playbook and is uploaded
    # once per host, keyed by content hash.
    def bridge_path : String
      if path = bridge_for_spec
        return path
      end
      dir = Process.executable_path.try { |exe_path| File.dirname(exe_path) } || "bin"
      File.join(dir, "krikri-ssm-pipe")
    end

    # The hidden entry point: rsync calls this with the host label first and
    # the server arguments after it (each already quoted for a remote shell
    # by rsync), so joining them with spaces reproduces what ssh would have
    # run on the target.
    def run(argv : Array(String), input : IO = STDIN, output : IO = STDOUT,
            error : IO = STDERR) : Int32
      settings = settings_from_env
      unless settings
        error.puts "#{NAME}: #{ENV_SETTINGS} is not set"
        return 255
      end
      if argv.size < 2
        error.puts "#{NAME}: no remote command was passed by rsync"
        return 255
      end

      command = argv[1..].join(" ")
      timeout = ENV[ENV_TIMEOUT]?.try(&.to_i?).try { |value| value > 0 ? value : nil } ||
                SsmTransport::DEFAULT_TIMEOUT
      conn = connection_for(settings)
      local_script = File.tempname("krikri-ssm-rsync", ".sh")

      bridge = bridge_path
      unless File.exists?(bridge)
        error.puts "#{NAME}: target bridge not found at #{bridge}"
        return 255
      end

      begin
        remote_bridge = ensure_bridge(conn, bridge, timeout)
        # Same hardened staging tree as the bridge and the plugin binaries -
        # /tmp is unreliable (and often remounted) on hardened targets.
        remote_script = File.join(File.dirname(remote_bridge), "krikri-ssm-rsync-#{Random::Secure.hex(8)}.sh")
        File.write(local_script, remote_script_body(command, remote_bridge))
        SsmTransport.upload(conn, local_script, remote_script, mode: 0o700)
        result = SsmTransport.pipe(conn, remote_script, input, output, timeout)
        error.puts(result[:stderr]) unless result[:stderr].empty?
        result[:exit_code]
      ensure
        File.delete(local_script) if File.exists?(local_script)
        # The pipe replaced the session's shell, so the session cannot serve
        # another operation; the bridge may also still be draining the pty.
        SsmRegistry.close_connection(conn.host_name, settings.target)
      end
    rescue ex : SsmTransport::Error
      error.puts ex.message
      255
    rescue ex
      error.puts "#{NAME}: #{ex.message}"
      255
    end

    # The runner uploaded to the target. Its command was quoted by rsync for
    # a remote shell, so it is spliced in as shell source after the bridge,
    # which gives the command real pipes.
    def remote_script_body(command : String, bridge : String) : String
      q_bridge = Shell.quote_arg(bridge)
      String.build do |io|
        io << "rm -f \"$0\"\n"
        io << "BRIDGE=" << q_bridge << "\n"
        # Probe the bridge before the marker: an exec-format or loader error
        # (a foreign-arch or corrupt build) then reaches the client as text,
        # instead of being mistaken for protocol data or lost behind 2>/dev/null.
        io << "if ! OUT=$(\"$BRIDGE\" --probe 2>&1); then "
        io << "echo \"krikri-ssm-pipe: cannot execute $BRIDGE: $OUT\" >&2; exit 126; fi\n"
        # Raw mode is what makes a binary protocol work at all: canonical
        # mode would truncate at MAX_CANON, split at every LF, and the pty's
        # echo would corrupt the client's bytes. If it cannot be enabled,
        # fail before the marker: the client must never start writing binary
        # into a still-canonical terminal.
        io << "stty raw -echo 2>/dev/null || exit 125\n"
        io << "printf '\\n%s%s\\n' \"$KRIKRI_SSM_PIPE_START_A\" \"$KRIKRI_SSM_PIPE_START_B\"\n"
        # The bridge discards the command's stderr (it would corrupt the
        # protocol); rsync's own errors travel over the protocol, and the
        # exit status reaches the client through the agent's ExitCode.
        io << "exec \"$BRIDGE\" " << command << " 2>/dev/null\n"
      end
    end

    UNSAFE_STAGING_EXIT = 75

    # Puts the bridge on the target once per (binary content, host) and
    # returns its remote path. The hash in the name makes a newer controller
    # binary upload under a new name instead of running a stale copy. It
    # lives in the same hardened per-user staging tree as the plugin
    # binaries: /var/tmp (not /tmp), 0711 directories, ownership and symlink
    # checks before anything is written - a pre-existing foreign-owned path
    # means a local user planted it, so that fails loudly instead of running.
    private def self.ensure_bridge(conn : ConnectionSettings, bridge : String,
                                   timeout : Int32) : String
      digest = Digest::SHA256.hexdigest(File.read(bridge))[0, 16]
      dir = RemoteStaging.plugin_dir(conn.staging_user)
      remote = File.join(dir, "krikri-ssm-pipe-#{digest}")
      check = SsmTransport.exec(conn, staging_check_script(dir, remote), timeout)
      case check[:exit_code]
      when 0
        # Already staged by an earlier run.
      when 1
        SsmTransport.upload(conn, bridge, remote, mode: 0o755)
      else
        detail = check[:stderr].strip
        raise SsmTransport::Error.new(detail.empty? ? "#{NAME}: unusable staging directory #{dir}" : detail)
      end
      remote
    end

    # Creates/validates the staging hierarchy and reports whether the bridge
    # is already usable there: exit 0 = ready, 1 = missing (upload it), 75 =
    # unsafe. Every component - both directories AND the bridge file itself -
    # is checked for symlinks/foreign ownership; `test -x` alone would follow
    # a planted symlink. Files older than an hour are pruned (a concurrent run
    # may still have a fresh one staged; deleting a running binary is safe).
    private def self.staging_check_script(dir : String, remote : String) : String
      base = File.dirname(dir)
      q_base = Shell.quote_arg(base)
      q_dir = Shell.quote_arg(dir)
      q_remote = Shell.quote_arg(remote)
      foreign = Shell.quote_arg("#{NAME}: staging path is foreign-owned or a symlink on this host")
      changed = Shell.quote_arg("#{NAME}: staging path changed owner mid-setup")
      unsafe_file = Shell.quote_arg("#{NAME}: staged bridge is a symlink, not a regular file, or foreign-owned")
      String.build do |io|
        io << "for D in " << q_base << ' ' << q_dir << "; do "
        io << "if [ -L \"$D\" ] || { [ -e \"$D\" ] && [ \"$(stat -c %u \"$D\")\" != \"$(id -u)\" ]; }; then "
        io << "echo " << foreign << " >&2; exit #{UNSAFE_STAGING_EXIT}; fi; done; "
        io << "mkdir -p " << q_dir << " || exit #{UNSAFE_STAGING_EXIT}; "
        io << "for D in " << q_base << ' ' << q_dir << "; do "
        io << "if [ \"$(stat -c %u \"$D\")\" != \"$(id -u)\" ]; then "
        io << "echo " << changed << " >&2; exit #{UNSAFE_STAGING_EXIT}; fi; "
        io << "chmod 711 \"$D\"; done; "
        io << "for F in " << q_dir << "/krikri-ssm-pipe-* " << q_dir << "/krikri-ssm-rsync-*.sh; do "
        io << "[ \"$F\" = " << q_remote << " ] && continue; "
        io << "[ -n \"$(find \"$F\" -maxdepth 0 -mmin +60 2>/dev/null)\" ] && rm -f \"$F\"; done; "
        io << "if [ -e " << q_remote << " ]; then "
        io << "if [ -L " << q_remote << " ] || [ ! -f " << q_remote << " ] || [ \"$(stat -c %u " << q_remote << ")\" != \"$(id -u)\" ]; then "
        io << "echo " << unsafe_file << " >&2; exit #{UNSAFE_STAGING_EXIT}; fi; "
        io << "exit 0; fi; exit 1"
      end
    end

    private def self.connection_for(settings : SsmSettings) : ConnectionSettings
      ConnectionSettings.new(
        settings.target, SsmSettings::SESSION_OS_USER, nil, nil, nil,
        [] of String, [] of String,
        host_name: settings.target, connection_type: "amazon.aws.aws_ssm", ssm: settings
      )
    end

    private def self.settings_from_env : SsmSettings?
      payload = ENV[ENV_SETTINGS]?
      return nil unless payload
      json = JSON.parse(payload)
      SsmSettings.new(
        json["target"].as_s,
        region: json["region"]?.try(&.as_s?) || SsmSettings::DEFAULT_REGION,
        profile: json["profile"]?.try(&.as_s?),
        document: json["document"]?.try(&.as_s?),
        timeout: json["timeout"]?.try(&.as_i?) || SsmSettings::DEFAULT_TIMEOUT,
        retries: json["retries"]?.try(&.as_i?) || SsmSettings::DEFAULT_RETRIES,
        endpoint_url: json["endpoint_url"]?.try(&.as_s?),
        access_key_id: json["access_key_id"]?.try(&.as_s?),
        secret_access_key: json["secret_access_key"]?.try(&.as_s?),
        session_token: json["session_token"]?.try(&.as_s?),
        shell_type: json["shell_type"]?.try(&.as_s?),
        windows_vars: json["windows_vars"]?.try(&.as_bool?) || false
      )
    end
  end
end
