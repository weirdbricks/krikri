#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_ref"
require "../src/krikri/plugin_helpers/docker_client"

module Krikri
  # docker_image_build plugin - builds a Docker image via the `docker
  # buildx build` CLI. Compatible with (a subset of) Ansible's
  # community.docker.docker_image_build module.
  #
  # Unlike docker_image.cr (which talks to the Docker Engine API
  # directly), buildx builds have no API equivalent - real Ansible's own
  # module shells out to the `docker buildx build` CLI too, so this
  # plugin does the same via #remote_exec. Image-existence checking (for
  # the rebuild: never idempotency check) still goes straight to the
  # Engine API, same approach as docker_image.cr.
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
  # mutually_exclusive/no_log censoring), because real Ansible runs all
  # of it in AnsibleModule setup BEFORE the module body's buildx probe
  # and path checks.
  class DockerImageBuildPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation
    # Real module's argument_spec (community.docker docker_image_build.py
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
    # Engine-internal executor keys that never reach the real module's
    # params (see apt.cr's same exclusion list).
    INTERNAL_PARAMS = {"_ansible_check_mode", "_ansible_diff", "_verbosity", "_environment"}
    # Sub-spec option names, for the deferred unsupported-params check.
    SECRETS_SUBOPTIONS = %w[id type src env value]
    OUTPUTS_SUBOPTIONS = %w[type dest context name push]
    # Only the secrets sub-spec has a no_log option (value).
    NO_LOG_SUBOPTIONS = {"secrets" => ["value"], "outputs" => [] of String}
    # convert_bool.py's BOOLEANS_TRUE / BOOLEANS_FALSE (the string
    # members; int/bool members can't reach a plugin - wire values are
    # always strings).
    REAL_TRUE  = %w[y yes on 1 true t]
    REAL_FALSE = %w[n no off 0 false f]
    # convert_bool.py's BOOLEANS (repr'd, TRUE set then FALSE set) - real
    # Ansible iterates a Python SET here, so the order differs between
    # processes (PYTHONHASHSEED); this fixed order is one of the orders
    # real emits.
    BOOLEANS_REPR = %w[y yes on '1' 'true' 't' 1 1.0 True n no off '0' 'false' 'f' 0 0.0 False]

    @no_log_values = [] of String

    def execute : PluginResult
      result = execute_validated
      # Real Ansible's remove_values() runs over the ENTIRE fail/exit
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

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      existing_image = image_id(client, PluginHelpers::DockerRef.join(ref_name, tag))

      if existing_image && rebuild == "never"
        return PluginResult.new(changed: false, failed: false, msg: "Image #{ref_name}:#{tag} already present")
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would build image #{ref_name}:#{tag} (check mode)") if check_mode

      args = build_args(ref_name, tag, path)
      build_result = remote_exec("docker #{args.join(" ")}")

      unless build_result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Building #{ref_name}:#{tag} failed", stdout: build_result[:stdout], stderr: build_result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Built image #{ref_name}:#{tag}", stdout: build_result[:stdout], stderr: build_result[:stderr])
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    # Real AnsibleModule validation for this module's argument_spec,
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
             "The value '#{raw}' is not a valid boolean.  Valid booleans include: #{BOOLEANS_REPR.join(", ")}")
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
             "The value '#{raw.as_s}' is not a valid boolean.  Valid booleans include: #{BOOLEANS_REPR.join(", ")}")
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

    private def build_args(ref_name : String, tag : String, path : String) : Array(String)
      args = ["buildx", "build", "--progress", "plain", "--tag", shell_quote("#{ref_name}:#{tag}")]

      if dockerfile = @params["dockerfile"]?
        args << "--file" << shell_quote(File.join(path, dockerfile))
      end
      each_list_param("cache_from") { |v| args << "--cache-from" << shell_quote(v) }
      args << "--pull" if true?(@params["pull"]?)
      if network = @params["network"]?
        args << "--network" << shell_quote(network)
      end
      args << "--no-cache" if true?(@params["nocache"]?)
      each_dict_param("args") { |k, v| args << "--build-arg" << shell_quote("#{k}=#{v}") }
      if target = @params["target"]?
        args << "--target" << shell_quote(target)
      end
      each_list_param("platform") { |v| args << "--platform" << shell_quote(v) }
      each_dict_param("labels") { |k, v| args << "--label" << shell_quote("#{k}=#{v}") }

      args << "--" << shell_quote(path)
      args
    end

    private def each_list_param(key : String, &) : Nil
      raw = @params[key]?
      return unless raw

      # ONLY valid JSON - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in real
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

    # Same raw-GET, minimal-trust approach as docker_image.cr's own
    # #image_id (see that plugin's doc comment) - nil if the image
    # doesn't exist.
    private def image_id(client : Docr::Client, ref : String) : String?
      id = nil
      client.call("GET", "/images/#{ref}/json") do |response|
        id = JSON.parse(response.body_io).dig?("Id").try(&.as_s?)
      end
      id
    rescue ex : Docr::Errors::DockerAPIError
      return nil if ex.status_code == 404
      raise ex
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DockerImageBuildPlugin.new(config)
plugin.run
