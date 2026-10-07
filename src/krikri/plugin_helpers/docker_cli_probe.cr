require "json"
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

      # The daemon URL common_cli.py falls back to when neither a
      # docker_host nor a cli_context is in play (DEFAULT_DOCKER_HOST).
      DEFAULT_HOST = "unix:///var/run/docker.sock"

      # The argv prefix real's DockerCLIClient builds once in
      # common_cli.py (self._cli_base) and prepends to EVERY CLI call it
      # makes: the docker_cli param (or the plain `docker` name - #probe
      # has already proved it resolves when it runs first), then
      # `--host <docker_host>` unless a cli_context: is in play (real's
      # own rule: no docker_host and no cli_context means the default
      # daemon URL, still passed explicitly).
      def self.base_args(docker_cli : String?, docker_host : String?, cli_context : String?) : Array(String)
        args = [docker_cli.presence || "docker"]
        args << "--host" << (docker_host.presence || DEFAULT_HOST) unless cli_context.presence
        args
      end

      # #base_args rendered for embedding in a shell command string
      # (shlex.quote semantics - bare when safe, matching how real's
      # _compose_cmd_str/_clean_args render the same argv).
      def self.base_command(docker_cli : String?, docker_host : String?, cli_context : String?) : String
        base_args(docker_cli, docker_host, cli_context).map { |arg| shlex_quote(arg) }.join(" ")
      end

      # The resolved docker CLI path (the docker_cli param, else the
      # `command -v docker` resolution) alongside the probe outcome - the
      # buildx gate needs the same path real's get_cli() renders into its
      # failure message.
      record Result, failure : Failure?, cli : String

      # Runs the probe through *run* (the plugin's remote_exec). Returns
      # a Result whose #failure is nil when the daemon answered, otherwise
      # the Failure to fail the task with.
      def self.probe(run : Runner, docker_cli : String?, docker_host : String?, cli_context : String? = nil) : Result
        cli = docker_cli.presence
        if cli.nil?
          resolved = run.call("command -v docker")
          if resolved[:exit_code] != 0 || resolved[:stdout].strip.empty?
            return Result.new(failure: missing_cli_failure, cli: "")
          end
          cli = resolved[:stdout].strip
        end

        # common_cli.py: no docker_host and no cli_context => the default
        # daemon URL, passed explicitly (the CLI would otherwise consult
        # its own context configuration).
        args = base_args(cli, docker_host, cli_context)
        args += ["version", "--format", "{{ json . }}"]

        cmd = args.map { |arg| shlex_quote(arg) }.join(" ")
        result = run.call(cmd)
        return Result.new(failure: nil, cli: cli) if result[:exit_code] == 0

        failure = Failure.new(
          cmd: cmd,
          # run_command(check_rc=True)'s fail_json: msg = stderr rstrip
          # (heuristic_log_sanitize has nothing to blank here).
          msg: result[:stderr].rstrip,
          rc: result[:exit_code],
          stdout: result[:stdout],
          stderr: result[:stderr])
        Result.new(failure: failure, cli: cli)
      end

      # Real's buildx-plugin gate (docker_image_build.py's
      # ImageBuilder.__init__): get_client_plugin_info('buildx') runs
      # `docker info --format '{{ json . }}'` (call_cli_json,
      # check_rc=True) and scans ClientInfo.Plugins for Name == 'buildx'
      # - BEFORE any path/tag validation and before any Engine-API use.
      # A host whose docker CLI has no buildx plugin (e.g. docker.io's
      # package without docker-buildx installed) fails right here with
      # "Docker CLI <cli> does not have the buildx plugin installed"
      # (cli = get_cli(): the docker_cli param, else the resolved PATH
      # entry), a plain fail_json shape.
      # The other failure arms real can reach first, same mechanisms as
      # the version probe:
      # - non-zero rc: run_command(check_rc=True)'s shape (msg = stderr);
      # - unparseable stdout: call_cli_json's own fail_json("Error while
      #   parsing JSON output of <cmd>: <exc>\nJSON output: ...\n\nError
      #   output:\n<stderr>", cmd=..., rc=..., stdout=..., stderr=...) -
      #   kwargs lead, so the same key shape as the run_command failure
      #   (the exception text is Python simplejson's, not Crystal's);
      # - ClientInfo absent/not a dict: "Cannot determine Docker client
      #   information. Are you maybe using podman instead of docker?".
      # The plugin-version comparisons real does next (LooseVersion vs
      # 0.6.0 for secrets of type=env/value, vs 0.13.0 for more than one
      # output) never fire here: secrets/outputs are rejected by the
      # plugin's unsupported-parameters validation before this runs.
      def self.buildx_check(run : Runner, cli : String, docker_host : String?, cli_context : String?) : Failure?
        args = base_args(cli, docker_host, cli_context) + ["info", "--format", "{{ json . }}"]
        cmd = args.map { |arg| shlex_quote(arg) }.join(" ")

        result = run.call(cmd)
        unless result[:exit_code] == 0
          return Failure.new(
            cmd: cmd,
            msg: result[:stderr].rstrip,
            rc: result[:exit_code],
            stdout: result[:stdout],
            stderr: result[:stderr])
        end

        begin
          info = JSON.parse(result[:stdout])
        rescue ex : JSON::ParseException
          return Failure.new(
            cmd: cmd,
            msg: "Error while parsing JSON output of #{cmd}: #{ex.message}\nJSON output: #{result[:stdout]}\n\nError output:\n#{result[:stderr]}",
            rc: result[:exit_code],
            stdout: result[:stdout],
            stderr: result[:stderr])
        end

        client_info = info.as_h?.try(&.["ClientInfo"]?)
        unless client_info && client_info.raw.is_a?(Hash)
          return plain_failure("Cannot determine Docker client information. Are you maybe using podman instead of docker?")
        end

        plugins = client_info.as_h["Plugins"]?
        plugins = nil unless plugins && plugins.raw.is_a?(Array)
        has_buildx = plugins.try(&.as_a.any? do |plugin|
          next false unless plugin.raw.is_a?(Hash)
          name = plugin.as_h["Name"]?
          name.try(&.as_s?) == "buildx"
        end)
        return nil if has_buildx

        plain_failure("Docker CLI #{cli} does not have the buildx plugin installed")
      end

      private def self.plain_failure(msg : String) : Failure
        Failure.new(cmd: nil, msg: msg, rc: 0, stdout: "", stderr: "")
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
      def self.shlex_quote(value : String) : String
        return "''" if value.empty?
        return value unless value.matches?(/[^\w@%+=:,.\/-]/)

        "'#{value.gsub("'", "'\\''")}'"
      end
    end
  end
end
