require "./docker_client"

module Krikri
  module PluginHelpers
    # DockerCliProbe - real community.docker's CLI-client modules
    # (docker_image_build, docker_compose_v2) construct a DockerCLIClient
    # BEFORE any module logic runs, and that constructor's first act is
    # `docker version --format '{{ json . }}'` through
    # run_command(check_rc=True) (module_utils/common_cli.py). A daemon
    # that cannot be reached therefore fails those modules at this probe
    # with the CLI's own stderr as the message - NOT the Python SDK's
    # "Error connecting: ..." wording the API-client modules use - plus
    # the run_command failure shape (cmd/rc/stdout/stderr + _lines).
    #
    # Reproduced here so both plugins run the same probe first: resolve
    # the docker CLI (get_bin_path('docker') - the CLI-process PATH, not
    # the controller's), then the probe with the CLI-client's common
    # args (`--host <docker_host>` whenever a docker_host is in play,
    # DEFAULT 'unix:///var/run/docker.sock' otherwise - real passes it
    # unconditionally unless cli_context: was given).
    module DockerCliProbe
      record Failure,
        # nil when the CLI itself was missing (real's
        # 'Cannot find docker CLI in path...' fail_json has no cmd/rc)
        cmd : String?,
        msg : String,
        rc : Int32,
        stdout : String,
        stderr : String

      alias Runner = String -> NamedTuple(exit_code: Int32, stdout: String, stderr: String)

      # Runs the probe through *run* (the plugin's remote_exec). Returns
      # nil when the daemon answered, otherwise the Failure to fail the
      # task with.
      def self.probe(run : Runner, docker_cli : String?, docker_host : String?, cli_context : String? = nil) : Failure?
        cli = docker_cli.presence
        if cli.nil?
          resolved = run.call("command -v docker")
          return missing_cli_failure if resolved[:exit_code] != 0 || resolved[:stdout].strip.empty?
          cli = resolved[:stdout].strip
        end

        args = [cli]
        # common_cli.py: no docker_host and no cli_context => the default
        # daemon URL, passed explicitly (the CLI would otherwise consult
        # its own context configuration).
        host = docker_host.presence || "unix:///var/run/docker.sock"
        args += ["--host", host] unless cli_context.presence
        args += ["version", "--format", "{{ json . }}"]

        cmd = args.map { |arg| shlex_quote(arg) }.join(" ")
        result = run.call(cmd)
        return nil if result[:exit_code] == 0

        Failure.new(
          cmd: cmd,
          # run_command(check_rc=True)'s fail_json: msg = stderr rstrip
          # (heuristic_log_sanitize has nothing to blank here).
          msg: result[:stderr].rstrip,
          rc: result[:exit_code],
          stdout: result[:stdout],
          stderr: result[:stderr])
      end

      private def self.missing_cli_failure : Failure
        # common_cli.py's get_bin_path failure - a plain fail_json(msg=...),
        # no cmd/rc/stdout/stderr.
        Failure.new(cmd: nil, msg: "Cannot find docker CLI in path. Please provide it explicitly with the docker_cli parameter", rc: 0, stdout: "", stderr: "")
      end

      # Python shlex.quote's split-quoting: bare when the value only
      # contains shlex's safe characters, single-quoted otherwise - the
      # same quoting real's _clean_args applies when it renders the cmd
      # string into the failure result (observed: '{{ json . }}' quoted,
      # paths and --host values bare).
      private def self.shlex_quote(value : String) : String
        return "''" if value.empty?
        return value unless value.matches?(/[^\w@%+=:,.\/-]/)

        "'#{value.gsub("'", "'\\''")}'"
      end
    end
  end
end
