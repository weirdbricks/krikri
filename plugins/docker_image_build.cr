#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_ref"
require "../src/krikri/plugin_helpers/docker_client"
require "../src/krikri/plugin_helpers/docker_cli_probe"

module Krikri
  # docker_image_build plugin - builds a Docker image via the `docker
  # buildx build` CLI. Compatible with (a subset of) Ansible's
  # community.docker.docker_image_build module.
  #
  # Unlike docker_image.cr (which talks to the Docker Engine API
  # directly), buildx builds have no API equivalent - Ansible's own
  # module shells out to the `docker buildx build` CLI too, so this
  # plugin does the same via #remote_exec. Image-existence checking (for
  # the rebuild: never idempotency check) goes through the CLI exactly
  # like real's find_image: `docker image ls --format '{{ json . }}'
  # --no-trunc --filter reference=<name>` plus the docker.io fallback
  # chain, then `docker image inspect <ID>` - so daemon failures surface
  # in the CLI run_command failure shape, not any SDK wording.
  #
  # Supported parameters: name (required), tag (default "latest"), path
  # (required), dockerfile, cache_from (list), pull (bool), network,
  # nocache (bool), args (dict, build-args), target, platform (list),
  # labels (dict), rebuild (never (default) / always), check_mode.
  #
  # Not implemented as build features (secrets, outputs, etc_hosts,
  # shm_size): advanced buildx-output/secret-passing features with no
  # bearing on the common "build an image from a Dockerfile" case -
  # but their AnsibleModule VALIDATION surface is fully implemented
  # below (required/choices/type conversion/sub-spec required_if/
  # mutually_exclusive/no_log censoring), because Ansible runs all
  # of it in AnsibleModule setup BEFORE the module body's buildx probe
  # and path checks.
  class DockerImageBuildPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation
    # Ansible module's argument_spec (community.docker docker_image_build.py
    # main()), in declaration order - validation iterates the MERGED spec
    # (common CLI-client args first, then the module's own) in this order,
    # so the first failing param names the surfaced error.
    SPEC_PARAMS = %w[name tag path dockerfile cache_from pull network nocache etc_hosts args target platform shm_size labels rebuild secrets outputs]
    # _common_cli.py's CLI-client DOCKER_COMMON_ARGS (NOT the API
    # client's: no timeout/use_ssh_client/debug, plus docker_cli and
    # cli_context instead) with their aliases.
    COMMON_CLI_SPEC = {
      "api_version"    => %w[docker_api_version],
      "ca_path"        => %w[ca_cert cacert_path tls_ca_cert],
      "client_cert"    => %w[cert_path tls_client_cert],
      "client_key"     => %w[key_path tls_client_key],
      "cli_context"    => %w[],
      "docker_cli"     => %w[],
      "docker_host"    => %w[docker_url],
      "tls"            => %w[],
      "tls_hostname"   => %w[],
      "validate_certs" => %w[tls_verify],
    }
    # Ansible's wrapper for the exception escaping the module body. The
    # module's `except DockerException` arm imports its class from
    # _common_cli, but resolve_repository_name raises _api/errors's
    # InvalidRepository (a DIFFERENT DockerException subclass), so the
    # module's catch never fires and the exception escapes uncaught -
    # ansible's module-outer wrapper builds the fatal result itself.
    # (The older comment here claimed CLI-side wrap wording that a 2026-
    # 10-06 session asserted without a witnessed run; round 5331000's
    # real host runs (docker CLI 29.1.3 + static buildx v0.17.0) refuse
    # that claim - see the live shapes below.)
    FATAL_MODULE_KEY_ORDER = %w[failed changed exception msg]

    # The wrap wording the module's own catch would produce; unreachable
    # for resolve_repository_name's raises, kept so a stray caller still
    # reads the same constant.
    API_ERROR_PREFIX = "An unexpected Docker error occurred: "

    # _api/auth.py resolve_repository_name, raising its errors.InvalidRepository
    # (a DockerException) exactly when real's find_image does: ONLY after the
    # `docker image ls --filter reference=<name>` lookup (and the docker.io
    # fallbacks) returned no rows, i.e. when our Engine-API lookup finds no
    # image. split_repo_name takes the part before the first "/" as the
    # "index" name unless it has no "/" (or that part has no dot/colon and
    # isn't "localhost", i.e. a docker.io repo); resolve_repository_name
    # rejects a scheme anywhere in the name and an index name beginning or
    # ending with a hyphen.
    def self.invalid_repository_error(name : String) : String?
      return "Repository name cannot contain a scheme (#{name})" if name.includes?("://")

      parts = name.split("/", 2)
      index_name = if parts.size < 2 || (!parts[0].includes?(".") && !parts[0].includes?(":") && parts[0] != "localhost")
                     "docker.io"
                   else
                     parts[0]
                   end
      if index_name[0] == '-' || index_name[-1] == '-'
        return "Invalid index name (#{index_name}). Cannot begin or end with a hyphen."
      end
      nil
    end

    # _api/auth.py split_repo_name + resolve_index_name, for find_image's
    # docker.io fallback chain: the part before the first "/" is the
    # "index" unless it has no dot/colon and isn't "localhost" (then it's
    # the whole name on the docker.io index); "index.docker.io" resolves
    # to "docker.io".
    def self.split_repo_name(name : String) : {String, String}
      parts = name.split("/", 2)
      index_name = if parts.size < 2 || (!parts[0].includes?(".") && !parts[0].includes?(":") && parts[0] != "localhost")
                     "docker.io"
                   else
                     parts[0]
                   end
      index_name = "docker.io" if index_name == "index.docker.io"
      remote = parts.size < 2 ? name : parts[1]
      {index_name, remote}
    end

    # Engine-internal executor keys that never reach the Ansible module's
    # params (see apt.cr's same exclusion list).
    INTERNAL_PARAMS = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
    # Sub-spec option names, for the deferred unsupported-params check.
    # Any executor-internal underscore-prefixed key (now or future) is also
    # excluded by validate_unsupported, so this set can't drift stale again.
    SECRETS_SUBOPTIONS = %w[id type src env value]
    OUTPUTS_SUBOPTIONS = %w[type dest context name push]
    # Only the secrets sub-spec has a no_log option (value).
    NO_LOG_SUBOPTIONS = {"secrets" => ["value"], "outputs" => [] of String}
    # convert_bool.py's BOOLEANS_TRUE / BOOLEANS_FALSE (the string
    # members; int/bool members can't reach a plugin - wire values are
    # always strings).
    REAL_TRUE  = %w[y yes on 1 true t]
    REAL_FALSE = %w[n no off 0 false f]
    # convert_bool.py's BOOLEANS (repr'd, TRUE set then FALSE set) -
    # Ansible iterates a Python SET here, so the order differs between
    # processes (PYTHONHASHSEED); this fixed order is one of the orders
    # Ansible emits.
    BOOLEANS_REPR = %w[y yes on '1' 'true' 't' 1 1.0 True n no off '0' 'false' 'f' 0 0.0 False]

    @no_log_values = [] of String

    # Real registered-result key order (live-verified vs ansible-core
    # 2.19.11 + community.docker 5.2.1 driving a real BuildKit builder -
    # rootless buildkitd reached as a buildx `remote` driver, with the
    # module's CLI probes talking to a podman `system service` socket):
    # - no build ran (already present / check mode): just the module's
    #   result dict - changed/actions/image - with no msg at all;
    # - a build ran successfully: the module dict (image updated after
    #   the build), then the controller-side stdout_lines/stderr_lines,
    #   then failed: false;
    # - a failed build: fail_json's kwargs (stdout/stderr/command) come
    #   first - fail_json appends failed/msg AFTER the kwargs it was
    #   handed - then the controller's *_lines, then the executor's
    #   changed: false and exception.
    SUCCESS_KEY_ORDER      = %w[changed actions image stdout stderr command stdout_lines stderr_lines failed]
    NO_BUILD_KEY_ORDER     = %w[changed actions image failed]
    FAILED_KEY_ORDER       = %w[stdout stderr command failed msg stdout_lines stderr_lines changed exception]
    PROBE_FAILED_KEY_ORDER = %w[cmd rc stdout stderr failed msg stdout_lines stderr_lines]

    def execute : PluginResult
      result = execute_validated
      # Ansible's remove_values() runs over the ENTIRE fail/exit
      # payload, so a no_log'd secrets[].value leaks into no message
      # (podman-diff docker_image_build_edge_cases B11: the literal
      # value "v" is blanked even inside the word "exclusive").
      result.msg = censor(result.msg)
      result
    end

    private def execute_validated : PluginResult
      if err = validate_arguments
        return err
      end

      # Real constructs its DockerCLIClient (common_cli.py) before any
      # module logic - get_bin_path('docker'), then
      # `docker --host ... version --format '{{ json . }}'` through
      # run_command(check_rc=True). A daemon that cannot be reached fails
      # right there, with the CLI's own stderr as the message and the
      # run_command failure shape, NOT the API client's SDK wording.
      probe = PluginHelpers::DockerCliProbe.probe(->(cmd : String) { remote_exec(cmd) }, @params["docker_cli"]?, PluginHelpers::DockerClient.resolved_docker_host(@params), @params["cli_context"]?)
      if failure = probe.failure
        return probe_failure_result(failure)
      end

      # Real's ImageBuilder.__init__ gates on the buildx CLI plugin
      # BEFORE any path/tag validation and before any Engine-API use:
      # `docker info --format '{{ json . }}'`, then a scan of
      # ClientInfo.Plugins for buildx. A host with docker.io installed
      # but no buildx plugin fails right here ("Docker CLI <cli> does
      # not have the buildx plugin installed", plain fail_json shape)
      # instead of reaching the image lookup or the build.
      if failure = PluginHelpers::DockerCliProbe.buildx_check(->(cmd : String) { remote_exec(cmd) }, probe.cli, PluginHelpers::DockerClient.resolved_docker_host(@params), @params["cli_context"]?)
        return probe_failure_result(failure)
      end

      path = @params["path"]?.to_s
      unless remote_dir_exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "\"#{path}\" is not an existing directory")
      end

      dockerfile = @params["dockerfile"]?
      if dockerfile && !remote_file_exists?(File.join(path, dockerfile))
        return PluginResult.new(changed: false, failed: true, msg: "\"#{File.join(path, dockerfile)}\" is not an existing file")
      end

      name = @params["name"]?.to_s
      ref_name, default_tag = PluginHelpers::DockerRef.split(name)
      tag = @params["tag"]? || default_tag
      rebuild = @params["rebuild"]? || "never"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Real's build_image starts with client.find_image(name, tag), which
      # resolves the image through the CLI - NOT the Engine API (the CLI
      # client module builds no API client at all). InvalidRepository
      # (resolve_repository_name) raises inside that chain when the first
      # lookup returned no rows; a daemon that rejects the reference
      # outright (podman's 301 on a scheme URL, its 500 on an invalid
      # reference) answers real's image-ls chain with "no rows" too, which
      # is exactly what gates the raise - raising the API error from a
      # pre-check here would resurface as the SDK's wording instead.
      lookup = cli_find_image(probe.cli, ref_name, tag)
      return failure if failure = lookup.failure
      if wrap = lookup.invalid_repo
        # Uncaught InvalidRepository escape: ansible's module-outer wrapper
        # builds the fatal result (round 5331000's live shape).
        result = PluginResult.new(changed: false, failed: true,
          msg: "Task failed: Module failed: #{wrap}")
        result.key_order = FATAL_MODULE_KEY_ORDER
        return result
      end
      existing_image = lookup.image

      # Ansible's build_image returns the module dict {changed, actions,
      # image} verbatim when the image already exists with rebuild: never
      # (BEFORE the check_mode branch, so a check-mode run against an
      # existing image lands here too) - no msg key at all.
      if existing_image && rebuild == "never"
        return no_build_result(existing_image, changed: false)
      end

      # Check mode on an absent image: Ansible still seeds image from
      # find_image - {} when the image isn't there - and reports changed:
      # true with no msg.
      return no_build_result(existing_image || JSON.parse("{}"), changed: true) if check_mode

      args = build_args(ref_name, tag, path)
      # Real runs the build through call_cli, i.e.
      # self._cli_base + args - the CLI binary with `--host
      # <docker_host>` in front (see DockerCliProbe.base_args), the same
      # prefix the version probe above already uses. The recorded
      # `command` stays the bare buildx argv: real's fail_json/exit_json
      # records `command=args`, without the base args.
      build_cmd = PluginHelpers::DockerCliProbe.base_command(@params["docker_cli"]?, PluginHelpers::DockerClient.resolved_docker_host(@params), @params["cli_context"]?)
      build_result = remote_exec("#{build_cmd} #{args.map { |arg| shell_quote(arg) }.join(" ")}")

      unless build_result[:exit_code] == 0
        result = PluginResult.new(changed: false, failed: true,
          msg: "Building #{ref_name}:#{tag} failed",
          stdout: build_result[:stdout], stderr: build_result[:stderr],
          stdout_lines: PluginHelpers::AnsibleSplitlines.split(build_result[:stdout]),
          stderr_lines: PluginHelpers::AnsibleSplitlines.split(build_result[:stderr]),
          command: json_string_array(args))
        result.key_order = FAILED_KEY_ORDER
        return result
      end

      # Real re-looks the image up after the build through the same CLI
      # find_image; a buildx backend that doesn't load the result into the
      # daemon's store (a remote driver's default output) leaves it at the
      # seeded {}.
      post = cli_find_image(probe.cli, ref_name, tag)
      return failure if failure = post.failure
      result = PluginResult.new(changed: true, failed: false, failed_flag: false,
        actions: json_string_array([] of String),
        image: post.image || JSON.parse("{}"),
        stdout: build_result[:stdout], stderr: build_result[:stderr],
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(build_result[:stdout]),
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(build_result[:stderr]),
        command: json_string_array(args))
      result.key_order = SUCCESS_KEY_ORDER
      result
    end

    # The run_command(check_rc=True) failure shape real's CLI probe fails
    # with: fail_json(cmd=..., rc=..., stdout=..., stderr=..., msg=...) -
    # kwargs in that order, then _return_formatted's stdout_lines/
    # stderr_lines, with changed/exception appended by the module
    # protocol. A missing CLI binary fails as a plain fail_json(msg=...)
    # (common_cli.py's get_bin_path failure - no cmd/rc at all).
    private def probe_failure_result(failure : PluginHelpers::DockerCliProbe::Failure) : PluginResult
      cmd = failure.cmd
      unless cmd
        return PluginResult.new(changed: false, failed: true, msg: failure.msg)
      end

      result = PluginResult.new(changed: false, failed: true, msg: failure.msg,
        cmd: JSON::Any.new(cmd),
        rc: JSON::Any.new(failure.rc.to_i64),
        stdout: JSON::Any.new(failure.stdout),
        stderr: JSON::Any.new(failure.stderr),
        stdout_lines: PluginHelpers::AnsibleSplitlines.split(failure.stdout),
        stderr_lines: PluginHelpers::AnsibleSplitlines.split(failure.stderr))
      result.key_order = PROBE_FAILED_KEY_ORDER
      result
    end

    # The no-build module dict shape: Ansible's results = {"changed": ...,
    # "actions": [], "image": image or {}} with no msg key at all -
    # exit_json is called without one (unlike the old "Image ... already
    # present"/"Would build image ..." texts this plugin used to emit).
    private def no_build_result(image : JSON::Any, changed : Bool) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, failed_flag: false,
        actions: json_string_array([] of String), image: image)
      result.key_order = NO_BUILD_KEY_ORDER
      result
    end

    # _common_cli.py's find_image/_image_lookup over the CLI (the module
    # builds no Engine API client at all): `docker image ls --format
    # '{{ json . }}' --no-trunc --filter reference=<name>` through
    # call_cli_json_stream(check_rc=True), the first Tag/Digest row match
    # when a tag is in play, the docker.io fallback chain when the first
    # lookup returned no rows (with resolve_repository_name's
    # InvalidRepository raise right after it), then a single
    # `docker image inspect <ID>` (call_cli_json, check_rc=False) whose
    # first row becomes the module's image dict. Daemon failures surface
    # in the shapes real produces: the run_command failure shape for a
    # failing image ls, the "Error while parsing JSON output of ..." shape
    # for unparseable CLI JSON, and plain fail_json for the >1-rows and
    # failed-inspect arms.
    private record CliImage, image : JSON::Any?, failure : PluginResult?, invalid_repo : String?
    private record CliRows, images : Array(JSON::Any), failure : PluginResult?
    private record CliInspect, image : JSON::Any?, failure : PluginResult?

    private def cli_find_image(cli : String, name : String, tag : String) : CliImage
      return CliImage.new(nil, nil, nil) if name.empty?

      outcome = image_lookup(cli, name, tag)
      return CliImage.new(nil, outcome.failure, nil) if outcome.failure
      images = outcome.images

      if images.empty?
        # resolve_repository_name raises InvalidRepository exactly here:
        # after the first lookup returned no rows, before any docker.io
        # fallback (those only run for the docker.io index anyway).
        if err = DockerImageBuildPlugin.invalid_repository_error(name)
          return CliImage.new(nil, nil, err)
        end
        registry, repo_name = DockerImageBuildPlugin.split_repo_name(name)
        if registry == "docker.io"
          outcome = image_lookup(cli, repo_name, tag)
          return CliImage.new(nil, outcome.failure, nil) if outcome.failure
          images = outcome.images
          if images.empty? && repo_name.starts_with?("library/")
            outcome = image_lookup(cli, repo_name["library/".size..], tag)
            return CliImage.new(nil, outcome.failure, nil) if outcome.failure
            images = outcome.images
          end
          if images.empty?
            outcome = image_lookup(cli, "#{registry}/#{repo_name}", tag)
            return CliImage.new(nil, outcome.failure, nil) if outcome.failure
            images = outcome.images
          end
          if images.empty? && !repo_name.includes?("/")
            outcome = image_lookup(cli, "#{registry}/library/#{repo_name}", tag)
            return CliImage.new(nil, outcome.failure, nil) if outcome.failure
            images = outcome.images
          end
        end
      end

      return CliImage.new(nil, nil, nil) if images.empty?
      if images.size > 1
        return CliImage.new(nil, PluginResult.new(changed: false, failed: true,
          msg: "Daemon returned more than one result for #{name}:#{tag}"), nil)
      end

      inspected = image_inspect_via_cli(cli, name, tag, images[0])
      return CliImage.new(nil, inspected.failure, nil) if inspected.failure
      CliImage.new(inspected.image, nil, nil)
    end

    private def image_lookup(cli : String, name : String, tag : String) : CliRows
      args = PluginHelpers::DockerCliProbe.base_args(cli, PluginHelpers::DockerClient.resolved_docker_host(@params), @params["cli_context"]?) +
             ["image", "ls", "--format", "{{ json . }}", "--no-trunc", "--filter", "reference=#{name}"]
      cmd = args.map { |arg| PluginHelpers::DockerCliProbe.shlex_quote(arg) }.join(" ")
      result = remote_exec(cmd)
      unless result[:exit_code] == 0
        return CliRows.new([] of JSON::Any, run_command_failure(cmd, result))
      end

      # call_cli_json_stream: one JSON object per stdout line (stripped,
      # only lines starting with '{'); a bad line fails the module with
      # cmd/rc/stdout/stderr attached.
      images = [] of JSON::Any
      result[:stdout].each_line do |line|
        line = line.strip
        next unless line.starts_with?("{")
        begin
          images << JSON.parse(line)
        rescue ex : JSON::ParseException
          return CliRows.new([] of JSON::Any, json_parse_failure(cmd, result, ex))
        end
      end

      # _image_lookup's own tag filter: the FIRST row whose Tag or Digest
      # matches - the row list collapses to 0 or 1 entries (only an empty
      # tag skips the filter and can leave more than one).
      unless tag.empty?
        matched = images.find do |image|
          image["Tag"]?.try(&.as_s?) == tag || image["Digest"]?.try(&.as_s?) == tag
        end
        images = matched ? [matched] : [] of JSON::Any
      end
      CliRows.new(images, nil)
    end

    private def image_inspect_via_cli(cli : String, name : String, tag : String, row : JSON::Any) : CliInspect
      image_id = row["ID"]?.try(&.as_s?) || ""
      args = PluginHelpers::DockerCliProbe.base_args(cli, PluginHelpers::DockerClient.resolved_docker_host(@params), @params["cli_context"]?) +
             ["image", "inspect", image_id]
      cmd = args.map { |arg| PluginHelpers::DockerCliProbe.shlex_quote(arg) }.join(" ")
      result = remote_exec(cmd)

      parsed = begin
        JSON.parse(result[:stdout])
      rescue ex : JSON::ParseException
        return CliInspect.new(nil, json_parse_failure(cmd, result, ex))
      end

      # real: `if not image: return None` runs BEFORE the rc check - an
      # empty inspect list means "not found" even on failure.
      unless (list = parsed.as_a?) && !list.empty?
        return CliInspect.new(nil, nil)
      end
      if result[:exit_code] != 0
        return CliInspect.new(nil, PluginResult.new(changed: false, failed: true,
          msg: "Error inspecting image #{name}:#{tag} - #{result[:stderr]}"))
      end
      CliInspect.new(list[0], nil)
    end

    # The run_command(check_rc=True) failure shape real's CLI probe fails
    # with: fail_json(cmd=..., rc=..., stdout=..., stderr=..., msg=...) -
    # kwargs in that order, then _return_formatted's stdout_lines/
    # stderr_lines, with changed/exception appended by the module
    # protocol. A missing CLI binary fails as a plain fail_json(msg=...)
    # (common_cli.py's get_bin_path failure - no cmd/rc at all).
    private def run_command_failure(cmd : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      probe_failure_result(PluginHelpers::DockerCliProbe::Failure.new(
        cmd: cmd,
        msg: result[:stderr].rstrip,
        rc: result[:exit_code],
        stdout: result[:stdout],
        stderr: result[:stderr]))
    end

    private def json_parse_failure(cmd : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String), ex : JSON::ParseException) : PluginResult
      probe_failure_result(PluginHelpers::DockerCliProbe::Failure.new(
        cmd: cmd,
        msg: "Error while parsing JSON output of #{cmd}: #{ex.message}\nJSON output: #{result[:stdout]}\n\nError output:\n#{result[:stderr]}",
        rc: result[:exit_code],
        stdout: result[:stdout],
        stderr: result[:stderr]))
    end

    # AnsibleModule validation for this module's argument_spec,
    # following ansible-core's arg_spec.ArgumentSpecValidator.validate
    # order - only the FIRST error ever surfaces (fail_json reports
    # errors[0]): _list_no_log_values (which runs FIRST and itself
    # fails a string-to-dict conversion for non-dict secrets/outputs
    # elements) -> mutually_exclusive -> required -> type conversion ->
    # choices -> required_together -> sub-spec (per element:
    # mutually_exclusive -> required -> types -> choices ->
    # required_if) -> unsupported parameters (deferred to last).
    private def validate_arguments : PluginResult?
      @no_log_values.clear
      if err = collect_no_log_values
        return err
      end

      if err = validate_mutually_exclusive
        return err
      end

      if err = validate_required
        return err
      end

      if err = validate_types
        return err
      end

      if err = validate_rebuild_choices
        return err
      end

      if err = validate_required_together
        return err
      end

      if err = validate_sub_specs
        return err
      end

      validate_unsupported
    end

    # _common_cli.py adds ("docker_host", "cli_context") to EVERY
    # CLI-client module's mutually_exclusive list.
    private def validate_mutually_exclusive : PluginResult?
      if @params["docker_host"]? && @params["cli_context"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: docker_host|cli_context")
      end
      nil
    end

    # _util.py's DOCKER_REQUIRED_TOGETHER, shared by every docker module.
    private def validate_required_together : PluginResult?
      has_cert = @params["client_cert"]? || @params["cert_path"]? || @params["tls_client_cert"]?
      has_key = @params["client_key"]? || @params["key_path"]? || @params["tls_client_key"]?
      if (has_cert || has_key) && !(has_cert && has_key)
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are required together: client_cert, client_key")
      end
      nil
    end

    # Real _list_no_log_values: walks every list-of-dict param with a
    # sub-spec BEFORE anything else, converting string elements through
    # check_type_dict ("banana" dies right here with the bare
    # "dictionary requested, could not parse JSON or key=value" - no
    # "argument ... is of type" wrapper) and harvesting no_log suboption
    # values for message censoring.
    private def collect_no_log_values : PluginResult?
      NO_LOG_SUBOPTIONS.each do |param, no_log_opts|
        raw = @params[param]?
        next unless raw
        parse_list_param(raw).each do |element|
          case element.raw
          when String
            # Real: sub_param = check_type_dict(sub_param) - the
            # conversion succeeds locally even for k1=v1 strings, but
            # the module params keep the string, so _validate_sub_spec
            # later rejects it; either way the element never survives.
            if err = check_dict_type_string(element.as_s)
              return err
            end
          when Hash
            no_log_opts.each do |opt|
              collect_no_log_strings(element.as_h[opt]?)
            end
          when Int64, Float64
            return PluginResult.new(changed: false, failed: true,
              msg: "Value '#{element}' in the sub parameter field '#{param}' must by a dict, not 'int'")
          end
        end
      end
      nil
    end

    private def collect_no_log_strings(value : JSON::Any?) : Nil
      return unless value
      case value.raw
      when String then @no_log_values << value.as_s unless value.as_s.empty?
      when Array  then value.as_a.each { |v| collect_no_log_strings(v) }
      when Hash   then value.as_h.each_value { |v| collect_no_log_strings(v) }
      end
    end

    private def validate_required : PluginResult?
      missing = %w[name path].select { |param| @params[param]?.nil? }
      return nil if missing.empty?
      PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: #{missing.join(", ")}")
    end

    # Real _validate_argument_types in argument_spec order; str/path
    # types cannot fail a string in ansible-core 2.14 (check_type_str
    # always converts), list elements-str cannot fail either - only
    # bool and dict params can.
    private def validate_types : PluginResult?
      {"tls", "validate_certs", "pull", "nocache"}.each do |param|
        next unless raw = @params[param]?
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      {"etc_hosts", "args", "labels"}.each do |param|
        next unless raw = @params[param]?
        if err = check_dict_type_param(param, raw)
          return err
        end
      end
      nil
    end

    private def bool_convertible?(raw : String) : Bool
      normalized = raw.downcase.strip
      REAL_TRUE.includes?(normalized) || REAL_FALSE.includes?(normalized)
    end

    private def bool_type_error(param : String, raw : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to bool: " \
             "The value '#{raw}' is not a valid boolean. Valid booleans include: #{BOOLEANS_REPR.join(", ")}")
    end

    # check_type_dict semantics for a TOP-LEVEL dict param (errors get
    # the parameters.py "argument ... is of type" wrapper here, unlike
    # the bare wording from the no_log pass above).
    private def check_dict_type_param(param : String, raw : String) : PluginResult?
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Hash
        nil
      when Array
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{param}' is of type <class 'list'> and we were unable to convert to dict: " \
               "<class 'list'> cannot be converted to a dict")
      when String
        if err = check_dict_type_string(value)
          return wrapped_dict_error(param, "<class 'str'>", err.msg)
        end
        nil
      when Nil
        if err = check_dict_type_string(raw)
          return wrapped_dict_error(param, "<class 'str'>", err.msg)
        end
        nil
      end
    end

    private def wrapped_dict_error(param : String, type_name : String, inner : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "argument '#{param}' is of type #{type_name} and we were unable to convert to dict: #{inner}")
    end

    # Bare check_type_dict: dict passes; strings try JSON (when they
    # look like objects) then k1=v1,k2=v2 pairs; everything else fails.
    private def check_dict_type_string(value : String) : PluginResult?
      stripped = value.strip
      if stripped.starts_with?("{")
        begin
          return nil if JSON.parse(stripped).as_h?
        rescue
        end
        return PluginResult.new(changed: false, failed: true,
          msg: "unable to evaluate string as dictionary")
      end
      return nil if value.includes?("=")
      PluginResult.new(changed: false, failed: true,
        msg: "dictionary requested, could not parse JSON or key=value")
    end

    private def validate_rebuild_choices : PluginResult?
      rebuild = @params["rebuild"]? || "never"
      return nil if %w[never always].includes?(rebuild)
      PluginResult.new(changed: false, failed: true,
        msg: "value of rebuild must be one of: never, always, got: #{rebuild}")
    end

    # Real _validate_sub_spec: per element, mutually_exclusive ->
    # required -> types -> choices -> required_if (the unsupported-
    # params tally is collected but only REPORTED after everything
    # else, so it never wins an earlier error).
    private def validate_sub_specs : PluginResult?
      validate_list_sub_spec("secrets").try do |err|
        return err
      end
      validate_list_sub_spec("outputs").try do |err|
        return err
      end
      nil
    end

    private def validate_list_sub_spec(param : String) : PluginResult?
      raw = @params[param]?
      return nil unless raw
      parse_list_param(raw).each do |element|
        unless element.as_h?
          return PluginResult.new(changed: false, failed: true,
            msg: "value of '#{param}' must be of type dict or list of dicts")
        end
        sub = element.as_h
        if err = sub_mutually_exclusive(param, sub)
          return err
        end
        if err = sub_required(param, sub)
          return err
        end
        if err = sub_types(param, sub)
          return err
        end
        if err = sub_choices(param, sub)
          return err
        end
        if err = sub_required_if(param, sub)
          return err
        end
      end
      nil
    end

    # secrets: mutually_exclusive [(src, env, value)]; outputs:
    # [(dest, name), (dest, push), (context, name), (context, push)].
    # ALL violating groups are listed in one message (real
    # check_mutually_exclusive collects before raising).
    private def sub_mutually_exclusive(param : String, sub : Hash(String, JSON::Any)) : PluginResult?
      groups = param == "secrets" ? [["src", "env", "value"]] : [["dest", "name"], ["dest", "push"], ["context", "name"], ["context", "push"]]
      violating = groups.select { |group| group.count { |k| sub.has_key?(k) } > 1 }
      return nil if violating.empty?
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: #{violating.map(&.join("|")).join(", ")} found in #{param}")
    end

    private def sub_required(param : String, sub : Hash(String, JSON::Any)) : PluginResult?
      required = param == "secrets" ? %w[id type] : %w[type]
      missing = required.select { |opt| !sub.has_key?(opt) }.sort!
      return nil if missing.empty?
      PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: #{missing.join(", ")} found in #{param}")
    end

    # Only the push suboption (outputs) is a bool; every str/path
    # suboption converts a string unconditionally in 2.14.
    private def sub_types(param : String, sub : Hash(String, JSON::Any)) : PluginResult?
      return nil unless param == "outputs"
      raw = sub["push"]?
      return nil unless raw
      return nil unless raw.as_s?
      return nil if bool_convertible?(raw.as_s)
      PluginResult.new(changed: false, failed: true,
        msg: "argument 'push' is of type <class 'str'> found in '#{param}'. and we were unable to convert to bool: " \
             "The value '#{raw.as_s}' is not a valid boolean. Valid booleans include: #{BOOLEANS_REPR.join(", ")}")
    end

    private def sub_choices(param : String, sub : Hash(String, JSON::Any)) : PluginResult?
      raw = sub["type"]?
      return nil unless raw
      value = raw.as_s? || raw.to_s
      allowed = param == "secrets" ? %w[file env value] : %w[local tar oci docker image]
      return nil if allowed.includes?(value)
      PluginResult.new(changed: false, failed: true,
        msg: "value of type must be one of: #{allowed.join(", ")}, got: #{value} found in #{param}")
    end

    # secrets: (type,file,[src]) (type,env,[env]) (type,value,[value]);
    # outputs: (type,local,[dest]) (type,tar,[dest]) (type,oci,[dest])
    # - first violation in list order raises.
    private def sub_required_if(param : String, sub : Hash(String, JSON::Any)) : PluginResult?
      reqs = param == "secrets" ? [{"type", "file", "src"}, {"type", "env", "env"}, {"type", "value", "value"}] : [{"type", "local", "dest"}, {"type", "tar", "dest"}, {"type", "oci", "dest"}]
      reqs.each do |req|
        next unless sub[req[0]]?.try(&.as_s?) == req[1]
        next if sub.has_key?(req[2])
        return PluginResult.new(changed: false, failed: true,
          msg: "#{req[0]} is #{req[1]} but all of the following are missing: #{req[2]} found in #{param}")
      end
      nil
    end

    # check_type_list semantics (ansible-core 2.14: no JSON probing - a
    # plain string is comma-split). The wire JSON round-trip is undone
    # first, since every krikri param arrives as a string.
    private def parse_list_param(raw : String) : Array(JSON::Any)
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Array
        value
      when String
        value.split(",").map { |entry| JSON::Any.new(entry) }
      when Nil
        raw.split(",").map { |entry| JSON::Any.new(entry) }
      else
        [JSON::Any.new(value)]
      end
    end

    private def validate_unsupported : PluginResult?
      unsupported = @params.keys.reject do |k|
        SPEC_PARAMS.includes?(k) || COMMON_CLI_SPEC.has_key?(k) ||
          COMMON_CLI_SPEC.values.any?(&.includes?(k)) || INTERNAL_PARAMS.includes?(k)
      end
      [{"secrets", SECRETS_SUBOPTIONS}, {"outputs", OUTPUTS_SUBOPTIONS}].each do |pair|
        param, suboptions = pair
        next unless raw = @params[param]?
        parse_list_param(raw).each do |element|
          next unless element.as_h?
          element.as_h.each_key do |k|
            unsupported << "#{param}.#{k}" unless suboptions.includes?(k)
          end
        end
      end
      return nil if unsupported.empty?
      unsupported_params_error("community.docker.docker_image_build", unsupported,
        COMMON_CLI_SPEC.merge(SPEC_PARAMS.to_h { |k| {k, [] of String} }))
    end

    # Real _remove_values_conditions: a string EQUAL to the secret
    # becomes VALUE_SPECIFIED_IN_NO_LOG_PARAMETER, any occurrence
    # inside a longer string becomes 8 asterisks.
    private def censor(msg : String) : String
      @no_log_values.each do |secret|
        next if secret.empty?
        msg = "VALUE_SPECIFIED_IN_NO_LOG_PARAMETER" if msg == secret
        msg = msg.gsub(secret, "*" * 8)
      end
      msg
    end

    # The buildx argv EXACTLY as Ansible's module builds it (the same list
    # real registers under `command`) - unquoted here; shell quoting for
    # #remote_exec happens at the call site.
    private def build_args(ref_name : String, tag : String, path : String) : Array(String)
      args = ["buildx", "build", "--progress", "plain", "--tag", "#{ref_name}:#{tag}"]

      if dockerfile = @params["dockerfile"]?
        args << "--file" << File.join(path, dockerfile)
      end
      each_list_param("cache_from") { |v| args << "--cache-from" << v }
      args << "--pull" if true?(@params["pull"]?)
      if network = @params["network"]?
        args << "--network" << network
      end
      args << "--no-cache" if true?(@params["nocache"]?)
      each_dict_param("args") { |k, v| args << "--build-arg" << "#{k}=#{v}" }
      if target = @params["target"]?
        args << "--target" << target
      end
      each_list_param("platform") { |v| args << "--platform" << v }
      each_dict_param("labels") { |k, v| args << "--label" << "#{k}=#{v}" }

      args << "--" << path
      args
    end

    private def json_string_array(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |value| JSON::Any.new(value) })
    end

    private def each_list_param(key : String, &) : Nil
      raw = @params[key]?
      return unless raw

      # ONLY valid JSON - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in
      # ansible-core (live-verified vs ansible-playbook 2.19.11, see
      # apt.cr's parse_package_names). A whole-value `{{ list_var }}`
      # container arg arrives as the double-quoted JSON the wire
      # serialized it to (see substitute_task_params's whole-single-span
      # comment).
      values = begin
        JSON.parse(raw).as_a.map(&.as_s)
      rescue
        [raw]
      end

      values.each { |v| yield v }
    end

    private def each_dict_param(key : String, &) : Nil
      raw = @params[key]?
      return unless raw

      hash = begin
        JSON.parse(raw).as_h
      rescue
        return
      end

      hash.each { |k, v| yield k, v.to_s }
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DockerImageBuildPlugin.new(config)
plugin.run
