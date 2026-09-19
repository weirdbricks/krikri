#!/usr/bin/env crystal
# community.docker.docker_compose_v2 - manages Docker Compose projects via
# the `docker compose` v2 CLI plugin. Ported from community.docker's
# docker_compose_v2 module (KNOWN_MISSING's "unimplemented collection
# modules" entry: mrlesmithjr.blocky uses it; previously rc=4 "unavailable
# modules" where real ansible rc=0'd).
#
# Mirrors the real module's structure (community.docker's
# module_utils/_compose_v2.py BaseComposeManager + the module's own
# get_up_cmd/get_down_cmd/get_restart_cmd/cmd_stop):
#   - state=present   -> `docker compose ... up --detach --no-color
#     --quiet-pull` (ALWAYS detached - there is no attach mode), flags
#     mapped 1:1 from pull/build/recreate/remove_orphans/
#     renew_anon_volumes/dependencies/timeout/scale/wait/wait_timeout/
#     assume_yes/services
#   - state=absent    -> `down [--remove-orphans] [--rmi all|local]
#     [--volumes]`
#   - state=restarted -> `restart`
#   - state=stopped   -> `up --no-start` (creates missing containers)
#     then - only when `docker compose ps` shows something still running
#     - `stop` (Compose's stop "always claims it is stopping containers",
#     so the real module gates the second command the same way)
#   - changed is computed from the command's own stderr event lines
#     (Container/Network/Volume/Image <id> <Status>, `<service> Pulling`,
#     image-layer pull progress), not hardcoded: only the "working"
#     statuses (Creating/Starting/Recreate/Stopping/Removing/Pulling/...)
#     count, never the done ones (Started/Created/Removed/Pulled/Built) -
#     that is what makes a warm `state: present` run converge to
#     changed=0. For up, service-level pull events are always ignored and
#     build events are ignored when ignore_build_events is true (the
#     default, matching the real module).
#   - check_mode appends --dry-run to every command and still computes
#     changed from the parsed dry-run events.
#
# Deliberate simplifications, each equivalent on every supported Compose:
#   - events are always parsed as TEXT (the real module switches to
#     --progress json + a JSON parser on Compose >= 2.29; the default
#     non-TTY progress output is the same text format either way, so the
#     parsed event set is identical)
#   - the Compose >= 2.18.0 minimum-version check is kept (real module's
#     own failure message), but the version probe is skipped when
#     `docker compose version` itself fails - the first real command
#     fails with its own error in that case, same net rc/changed
#   - definition: (a dict) is written to a temp compose.yaml via JSON
#     flow syntax - JSON is valid YAML, so Compose parses it identically
#     to the real module's safe_dump output
require "json"
require "../src/krikri/base_plugin"

module Krikri
  class DockerComposeV2Plugin < BasePlugin
    # Resolved in #execute: the project dir (given or the temp dir a
    # definition: was written to) - compose_base_args/capture_cmd need it
    # after the definition/proj_src mutual-exclusion logic ran.
    @project_src = ""

    # The real module's DOCKER_STATUS_WORKING - the only statuses that
    # ever flip changed to true (plus image-layer pull progress below).
    WORKING_STATUSES = %w[Creating Starting Restarting Stopping Killing Removing Recreate Pulling Building]
    # The real module's DOCKER_STATUS (done + working + pull + error +
    # waiting) - needed to distinguish `Container x <status>` from
    # `Container x <msg>` (the real parser swaps them when the third
    # token isn't a known status).
    KNOWN_STATUSES = WORKING_STATUSES + %w[Started Healthy Exited Restarted Running Created Stopped Killed Removed Recreated Pulled Built Error Waiting]
    # The real module's DOCKER_PULL_PROGRESS_WORKING - image-layer
    # progress lines that count as changes.
    PULL_PROGRESS_WORKING = %w[Pulling fs layer Waiting Downloading Verifying Checksum Extracting Working]

    # One parsed stderr event - the real module's Event namedtuple.
    record Event, type : String, id : String, status : String?, msg : String? = nil

    def execute : PluginResult
      check_mode = true?(@params["_ansible_check_mode"]?)
      state = @params["state"]? || "present"
      pull = @params["pull"]? || "policy"
      build = @params["build"]? || "policy"
      recreate = @params["recreate"]? || "auto"
      # Real AnsibleModule validation order (arg_spec.ArgumentSpecValidator
      # .validate): mutually_exclusive -> type conversion -> choices ->
      # required_one_of -> required_by.
      if err = validate_mutually_exclusive
        return err
      end

      if err = validate_arg_types
        return err
      end

      if err = validate_choices
        return err
      end

      if err = resolve_project
        return err
      end

      if err = validate_compose_version
        return err
      end

      # Real module's validation order: project dir first, then files.
      if err = validate_project_files
        return err
      end

      if state == "present"
        run_up(check_mode, pull, build, recreate)
      elsif state == "absent"
        run_down(check_mode)
      elsif state == "stopped"
        run_stop(check_mode, pull, build, recreate)
      else
        run_command(restart_cmd(check_mode), ignore_pulls: false, ignore_builds: false, check_mode: check_mode)
      end
    end

    # The real module's argspec choices - each param validated against
    # its own list, in argument_spec declaration order (AnsibleModule
    # renders them in that order).
    CHOICE_VALUES = {
      "state"         => %w[absent present stopped restarted],
      "pull"          => %w[always missing never policy],
      "build"         => %w[always never policy],
      "recreate"      => %w[always never auto],
      "remove_images" => %w[all local],
    }
    CHOICE_DEFAULTS = {
      "state"    => "present",
      "pull"     => "policy",
      "build"    => "policy",
      "recreate" => "auto",
    }

    private def validate_choices : PluginResult?
      CHOICE_VALUES.each do |param, allowed|
        value = @params[param]? || CHOICE_DEFAULTS[param]?
        next if value.nil?
        next if allowed.includes?(value)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of #{param} must be one of: #{allowed.join(", ")}, got: #{value}")
      end
      nil
    end

    # Real module's mutually_exclusive: [(definition, project_src),
    # (definition, files)] - key-presence based (count_terms intersects
    # parameter names, not values).
    private def validate_mutually_exclusive : PluginResult?
      return nil unless @params["definition"]?
      if @params["project_src"]?
        return mutually_exclusive_error("definition", "project_src")
      end
      if @params["files"]?
        return mutually_exclusive_error("definition", "files")
      end
      nil
    end

    private def mutually_exclusive_error(a : String, b : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: #{a}|#{b}")
    end

    # Real parameters.py type conversion, which runs before choice
    # validation: timeout/wait_timeout are int, definition/scale are dict.
    private def validate_arg_types : PluginResult?
      {"timeout", "wait_timeout"}.each do |param|
        next unless raw = @params[param]?
        next if int_convertible?(raw)
        type_name = json_type_name(raw)
        return type_error(param, type_name, "int", "#{type_name} cannot be converted to an int")
      end
      {"definition", "scale"}.each do |param|
        next unless raw = @params[param]?
        if err = convert_dict(param, raw)
          return err
        end
      end
      nil
    end

    private def int_convertible?(raw : String) : Bool
      parsed = JSON.parse(raw) rescue nil
      return raw.to_i32? != nil if parsed.nil? || parsed.as_s?
      case parsed.raw
      when Int64, Float64 then true
      else                     false
      end
    end

    # Incoming YAML type of a param value as it arrives on the wire (a
    # JSON string) - the real error messages embed Python's type(value).
    private def json_type_name(raw : String) : String
      parsed = JSON.parse(raw) rescue return "<class 'str'>"
      case parsed.raw
      when Hash    then "<class 'dict'>"
      when Array   then "<class 'list'>"
      when Int64   then "<class 'int'>"
      when Float64 then "<class 'float'>"
      when Bool    then "<class 'bool'>"
      else              "<class 'str'>"
      end
    end

    private def type_error(param : String, type_name : String, wanted : String, detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "argument '#{param}' is of type #{type_name} and we were unable to convert to #{wanted}: #{detail}")
    end

    # Real check_type_dict: dict passes; list (and other non-dict
    # containers/scalars) fail with "<class X> cannot be converted to a
    # dict"; strings try JSON then key=value pairs.
    private def convert_dict(param : String, raw : String) : PluginResult?
      parsed = JSON.parse(raw) rescue nil
      type_name = json_type_name(raw)
      case parsed.try(&.raw)
      when Hash
        nil
      when Array
        type_error(param, type_name, "dict", "#{type_name} cannot be converted to a dict")
      when String
        convert_dict_string(param, type_name, raw)
      when Nil
        # Not valid JSON at all - a plain (unquoted-on-the-wire) string.
        convert_dict_string(param, type_name, raw)
      else
        type_error(param, type_name, "dict", "#{type_name} cannot be converted to a dict")
      end
    end

    private def convert_dict_string(param : String, type_name : String, value : String) : PluginResult?
      stripped = value.strip
      if stripped.starts_with?("{")
        begin
          return nil if JSON.parse(stripped).as_h?
        rescue
        end
        return type_error(param, type_name, "dict", "unable to evaluate string as dictionary")
      end
      return nil if value.includes?("=")
      type_error(param, type_name, "dict", "dictionary requested, could not parse JSON or key=value")
    end

    private def resolve_project : PluginResult?
      definition = parse_definition_param
      project_src = @params["project_src"]?
      project_name = @params["project_name"]?
      if definition
        unless project_name
          return PluginResult.new(changed: false, failed: true,
            msg: "missing parameter(s) required by 'definition': project_name")
        end
        @project_src = write_definition(definition)
      else
        if project_src.nil? || project_src.empty?
          return PluginResult.new(changed: false, failed: true,
            msg: "one of the following is required: definition, project_src")
        end
        @project_src = expand_tilde(project_src)
      end
      nil
    end

    # definition: arrives on the wire as the stringified JSON of the
    # YAML dict (BasePlugin flattens every param to a String) - parse it
    # back out. A JSON null means the param was YAML null, i.e. the real
    # module's None (treated as not provided).
    private def parse_definition_param : JSON::Any?
      raw = @params["definition"]?
      return nil if raw.nil?
      parsed = JSON.parse(raw) rescue return nil
      parsed.as_h? ? parsed : nil
    end

    # Real module's minimum Compose version gate (same failure message).
    # A failed version probe is NOT an error - the first real command
    # surfaces its own failure (rc != 0) in that case, same net result.
    private def validate_compose_version : PluginResult?
      result = remote_exec("#{base_cli} compose version --format json")
      return nil if result[:exit_code] != 0
      parsed = JSON.parse(result[:stdout].strip) rescue nil
      return nil unless parsed && parsed.as_h?
      version = parsed["version"]?.try(&.as_s?).try(&.lchop("v"))
      return nil unless version && version != "dev" && compose_version_lt(version, "2.18.0")
      PluginResult.new(changed: false, failed: true,
        msg: "Docker CLI #{base_cli} has the compose plugin with version #{version}; need version 2.18.0 or later")
    end

    private def validate_project_files : PluginResult?
      return PluginResult.new(changed: false, failed: true, msg: "\"#{@project_src}\" is not a directory") if remote_dir_exists?(@project_src) == false

      files = split_list(@params["files"]?)
      files.each do |file|
        if remote_file_exists?("#{@project_src}/#{file.lchop("/")}") == false
          return PluginResult.new(changed: false, failed: true,
            msg: "Cannot find Compose file \"#{file}\" relative to project directory \"#{@project_src}\"")
        end
      end
      if files.empty? && false?(@params["check_files_existing"]?) == false
        default_files = %w[compose.yaml compose.yml docker-compose.yaml docker-compose.yml]
        if default_files.all? { |fname| remote_file_exists?("#{@project_src}/#{fname}") == false }
          return PluginResult.new(changed: false, failed: true,
            msg: "\"#{@project_src}\" does not contain compose.yaml, compose.yml, docker-compose.yaml, or docker-compose.yml")
        end
      end
      nil
    end

    # state=present: real module's get_up_cmd.
    private def run_up(check_mode : Bool, pull : String, build : String, recreate : String) : PluginResult
      ignore_builds = @params["ignore_build_events"]?.nil? || @params["ignore_build_events"] != "false"
      run_command(up_cmd(check_mode, pull, build, recreate, no_start: false),
        ignore_pulls: true, ignore_builds: ignore_builds, check_mode: check_mode)
    end

    # state=absent: real module's get_down_cmd.
    private def run_down(check_mode : Bool) : PluginResult
      args = ["down"]
      args << "--remove-orphans" if true?(@params["remove_orphans"]?)
      if remove_images = @params["remove_images"]?
        args << "--rmi" << remove_images if %w[all local].includes?(remove_images)
      end
      args << "--volumes" if true?(@params["remove_volumes"]?)
      args << "--timeout" << @params["timeout"] if @params["timeout"]?
      args << "--dry-run" if check_mode
      services = split_list(@params["services"]?)
      args << "--" unless services.empty?
      args.concat(services)
      run_command(args, ignore_pulls: false, ignore_builds: false, check_mode: check_mode)
    end

    # state=stopped: real module's cmd_stop - `up --no-start` first
    # (creates any missing containers), then `stop` only when something
    # is actually still running.
    private def run_stop(check_mode : Bool, pull : String, build : String, recreate : String) : PluginResult
      up = run_command(up_cmd(check_mode, pull, build, recreate, no_start: true),
        ignore_pulls: false, ignore_builds: false, check_mode: check_mode)
      return up if up.failed?

      return up if containers_all_stopped?

      args = ["stop"]
      args << "--timeout" << @params["timeout"] if @params["timeout"]?
      args << "--dry-run" if check_mode
      services = split_list(@params["services"]?)
      args << "--" unless services.empty?
      args.concat(services)
      run_command(args, ignore_pulls: false, ignore_builds: false, check_mode: check_mode)
    end

    # Real module's get_up_cmd - ALWAYS detached, --no-color --quiet-pull
    # unconditionally, every other flag strictly conditional.
    private def up_cmd(check_mode : Bool, pull : String, build : String, recreate : String, no_start : Bool) : Array(String)
      args = ["up", "--detach", "--no-color", "--quiet-pull"]
      args << "--pull" << pull unless pull == "policy"
      args << "--remove-orphans" if true?(@params["remove_orphans"]?)
      args << "--force-recreate" if recreate == "always"
      args << "--no-recreate" if recreate == "never"
      args << "--renew-anon-volumes" if true?(@params["renew_anon_volumes"]?)
      args << "--no-deps" if false?(@params["dependencies"]?) || @params["dependencies"]? == "false"
      args << "--timeout" << @params["timeout"] if @params["timeout"]?
      args << "--build" if build == "always"
      args << "--no-build" if build == "never"
      scale.each { |service, count| args << "--scale" << "#{service}=#{count}" }
      if true?(@params["wait"]?)
        args << "--wait"
        args << "--wait-timeout" << @params["wait_timeout"] if @params["wait_timeout"]?
      end
      args << "--no-start" if no_start
      args << "--dry-run" if check_mode
      args << "-y" if true?(@params["assume_yes"]?)
      services = split_list(@params["services"]?)
      args << "--" unless services.empty?
      args.concat(services)
      args
    end

    private def restart_cmd(check_mode : Bool) : Array(String)
      args = ["restart"]
      args << "--no-deps" if @params["dependencies"]? == "false"
      args << "--timeout" << @params["timeout"] if @params["timeout"]?
      args << "--dry-run" if check_mode
      services = split_list(@params["services"]?)
      args << "--" unless services.empty?
      args.concat(services)
      args
    end

    # scale: arrives as the stringified JSON of the YAML dict - parse it
    # back out (dict-ness was already enforced by validate_arg_types).
    private def scale : Array({String, String})
      raw = @params["scale"]?
      return [] of {String, String} if raw.nil?
      h = JSON.parse(raw).as_h? rescue nil
      return [] of {String, String} if h.nil? || h.empty?
      h.to_a.sort_by(&.[0]).map { |pair| {pair[0], pair[1].to_s} }
    end

    # Runs `<docker> compose <base args> <cmd args>` on the target and
    # turns the parsed stderr events into changed/failed - the port of
    # the real module's run-and-then-update_result/update_failed flow.
    private def run_command(cmd_args : Array(String), ignore_pulls : Bool, ignore_builds : Bool, check_mode : Bool) : PluginResult
      result = remote_exec(capture_cmd(cmd_args))
      events = parse_events(result[:stderr])

      if result[:exit_code] != 0
        errors = events.select { |e| e.status == "Error" }
        msg = errors.empty? ? "Return code #{result[:exit_code]} is non-zero" : errors.map { |e| "#{e.id}: #{e.msg}" }.join("\n")
        return PluginResult.new(changed: false, failed: true, msg: msg)
      end

      changed = has_changes?(events, ignore_pulls, ignore_builds)
      PluginResult.new(changed: changed, failed: false,
        msg: changed ? "Project #{project_label} changed" : "Project #{project_label} unchanged")
    end

    private def project_label : String
      @params["project_name"]? || @params["project_src"]? || ""
    end

    private def base_cli : String
      "docker"
    end

    # Real module's get_base_args (text-progress variant): --ansi never
    # always, then the project/file/env/profile wiring. Paths are
    # single-quoted - all of them can contain spaces.
    private def compose_base_args : Array(String)
      args = ["compose", "--ansi", "never"]
      args << "--project-directory" << q(project_src!)
      args << "--project-name" << q(@params["project_name"]) if @params["project_name"]?
      split_list(@params["files"]?).each { |file| args << "--file" << q(file) }
      split_list(@params["env_files"]?).each { |env_file| args << "--env-file" << q(env_file) }
      split_list(@params["profiles"]?).each { |profile| args << "--profile" << q(profile) }
      args
    end

    # Runs with cwd=project_src (the real module passes cwd= to every
    # call, so relative --file/--env-file paths resolve the same way).
    private def capture_cmd(cmd_args : Array(String)) : String
      "cd #{q(project_src!)} && #{base_cli} #{compose_base_args.join(" ")} #{cmd_args.join(" ")}"
    end

    private def project_src! : String
      @project_src
    end

    private def q(s : String) : String
      shell_single_quote(s)
    end

    # Real module's version gate (Docker CLI ... has the compose plugin
    # with version X; need version 2.18.0 or later). Skipped (nil error)
    # when the probe itself fails - the real command will surface its own
    # error in that case.
    private def compose_version_lt(a : String, b : String) : Bool
      a_parts = parse_version(a)
      b_parts = parse_version(b)
      return false if a_parts.nil? || b_parts.nil?
      {a_parts.size, b_parts.size}.max.times do |i|
        x = a_parts[i]? || 0
        y = b_parts[i]? || 0
        return true if x < y
        return false if x > y
      end
      false
    end

    private def parse_version(s : String) : Array(Int32)?
      parts = s.split(".").map(&.to_i?)
      return nil if parts.any?(Nil)
      parts.map { |part| part || 0 }
    end

    # Writes definition: to a temp compose.yaml the way the real module
    # does (mkdtemp + compose.yaml). JSON flow syntax IS valid YAML, so
    # Compose parses this identically to the real module's safe_dump.
    private def write_definition(definition : JSON::Any) : String
      dir = remote_exec("mktemp -d -t ansible.XXXXXX")[:stdout].strip
      File.write(File.join(dir, "compose.yaml"), definition.to_json)
      dir
    end

    private def split_list(value : String?) : Array(String)
      value.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
    end

    # Real module's _are_containers_stopped: `compose ps --format json
    # --all` - true when every container's State is in the stopped set
    # (or there are no containers at all).
    private def containers_all_stopped? : Bool
      stopped_states = %w[created exited stopped killed]
      result = remote_exec("cd #{q(project_src!)} && #{base_cli} #{compose_base_args.join(" ")} ps --format json --all")
      return true if result[:exit_code] != 0
      containers = result[:stdout].strip.lines.reject(&.empty?).select(&.starts_with?("{"))
      return true if containers.empty?
      containers.all? do |line|
        parsed = JSON.parse(line) rescue nil
        next true unless parsed && parsed.as_h?
        state = parsed["State"]?.try(&.as_s?) || parsed["state"]?.try(&.as_s?) || ""
        stopped_states.includes?(state.downcase)
      end
    end

    # Text-mode event parser - the port of the real module's
    # parse_events/_extract_event text path (its --progress json branch
    # is deliberately not ported, see the module comment). Events are
    # {resource_type, resource_id, status, msg}; only status matters for
    # changed/failed.
    private def parse_events(stderr : String) : Array(Event)
      events = [] of Event
      stderr.each_line do |raw|
        line = raw.gsub(/\e\[[0-9;]*m/, "").strip
        next if line.empty?
        line = line.lchop("DRY-RUN MODE - ").lstrip
        if m = line.match(/^(Network|Image|Volume|Container)\s+(\S+)\s+(.+)$/)
          status = m[3].strip
          known = KNOWN_STATUSES.includes?(status)
          # The real parser swaps status/msg when the third token isn't a
          # known status - a message-carrying event never counts as
          # working either way, so collapsing to status=nil is equivalent
          # for changed/failed purposes.
          events << Event.new(m[1], m[2], known ? status : nil)
        elsif m = line.match(/^(\S+)\s+(Pulling|Pulled)\s*$/)
          events << Event.new("Service", m[1], m[2])
        elsif m = line.match(/^(\S+)\s+Error\s*(.*)$/)
          events << Event.new("Unknown", m[1], "Error", m[2].presence)
        elsif line.starts_with?("Error ")
          events << Event.new("Unknown", "", "Error", line)
        elsif m = line.match(/^build service\s+(\S+)$/)
          events << Event.new("Service", m[1], "Building")
        elsif m = line.match(/^(\S+)\s+(Pulling fs layer|Waiting|Downloading|Verifying Checksum|Extracting|Working|Already exists|Download complete|Pull complete)(\s|$)/)
          events << Event.new("ImageLayer", m[1], m[2])
        end
      end
      events
    end

    # Real module's has_changes.
    private def has_changes?(events : Array(Event), ignore_pulls : Bool, ignore_builds : Bool) : Bool
      events.any? do |e|
        status = e.status
        next false unless status
        if WORKING_STATUSES.includes?(status)
          # ignore_service_pull_events only ignores SERVICE-type pull
          # events (the real module's has_changes does the same).
          next false if ignore_pulls && status == "Pulling" && e.type == "Service"
          next false if ignore_builds && status == "Building"
          true
        else
          e.type == "ImageLayer" && PULL_PROGRESS_WORKING.includes?(status)
        end
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DockerComposeV2Plugin.new(config)
plugin.run
