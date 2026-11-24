#!/usr/bin/env crystal

require "json"
require "krikri-docker"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_client"

module Krikri
  # Docker volume plugin - creates/removes a Docker volume. Compatible
  # with Ansible's community.docker.docker_volume module.
  #
  # See plugins/docker_network.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly, local
  # UNIX socket by default or a remote daemon over TCP(+TLS) via
  # docker_host:/TLS params, via the krikri-docker shard - connection
  # param parsing shared through PluginHelpers::DockerClient).
  #
  # Supported parameters (real's own argument_spec):
  # - volume_name (required, alias `name`): the volume to manage.
  # - driver: volume driver (default "local").
  # - driver_options: dict of driver-specific options (default {}).
  # - labels: dict of labels.
  # - recreate: always / never (default) / options-changed - controls
  #   when an existing volume whose driver/driver_options/labels differ
  #   from the request is deleted and recreated (losing its data).
  # - state: present (default) / absent.
  # - debug: keep `actions`/`diff` in the result outside check mode.
  # - docker_host: / tls: / validate_certs: (alias tls_verify:) /
  #   ca_path: / client_cert: / client_key: / tls_hostname: /
  #   api_version: / timeout: / use_ssh_client: - the common connection
  #   surface real merges into every API module's argument_spec (see
  #   PluginHelpers::DockerClient.COMMON_SPEC).
  # - check_mode / diff_mode: fully supported, including the same action
  #   and difference records real emits.
  #
  # An unreachable Docker daemon FAILS the task with real's connection
  # error ("Error connecting: Error while fetching server API
  # version: ...") - these modules never silently skip, and the
  # connection is attempted before the module body (real's client
  # construction negotiates the API version first), so it wins over an
  # invalid labels: value exactly like real.
  class DockerVolumePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real merged argument_spec (community.docker docker_volume.py +
    # _util.py's DOCKER_COMMON_ARGS), name => aliases.
    SPEC = PluginHelpers::DockerClient::COMMON_SPEC.merge({
      "volume_name"    => %w[name],
      "state"          => [] of String,
      "driver"         => [] of String,
      "driver_options" => [] of String,
      "labels"         => [] of String,
      "recreate"       => [] of String,
    })
    # Real merged-spec order for type conversion (common args first;
    # debug is in both, the module's own entry wins by key).
    INT_PARAMS    = %w[timeout]
    BOOL_PARAMS   = %w[tls use_ssh_client validate_certs debug]
    DICT_PARAMS   = %w[driver_options labels]
    CHOICE_PARAMS = {
      "state"    => %w[present absent],
      "recreate" => %w[always never options-changed],
    }

    # Key order of Ansible's registered result: the module seeds
    # `{"changed": ..., "actions": [...]}`, present() drops `actions`
    # again on a real (non-check, non-debug) run and adds `volume`,
    # then __init__ adds `diff` in check_mode/debug/--diff, and the
    # module protocol appends `failed` last.
    KEY_ORDER = %w[changed actions volume diff failed]

    # Ansible's own wrapper for a DockerException escaping the module body;
    # the wrapped text is the Python SDK's own APIError rendering, which
    # PluginHelpers::DockerSdkError reproduces.
    API_ERROR_PREFIX = "An unexpected Docker error occurred: "

    # The task's parameters after Ansible's own defaulting
    # (TaskParameters.__init__ copies the argspec defaults over the
    # module params).
    record VolumeSettings,
      name : String,
      driver : String,
      driver_options : Hash(String, JSON::Any),
      labels_given : Bool,
      recreate : String,
      state : String,
      check_mode : Bool,
      debug_mode : Bool,
      diff_mode : Bool

    def execute : PluginResult
      resolve_aliases

      if err = validate_arguments
        return err
      end

      settings = volume_settings
      client = connect_volume_client
      labels = sanitized_labels
      return labels if labels.is_a?(PluginResult)

      existing = find_volume(client, settings.name)
      if settings.state == "present"
        ensure_present(client, settings, labels, existing)
      else
        ensure_absent(client, settings, existing)
      end
    rescue ex : VolumeApiFailure
      PluginResult.new(changed: false, failed: true, msg: ex.message || "")
    rescue ex : KrikriDocker::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "#{API_ERROR_PREFIX}#{PluginHelpers::DockerSdkError.api_error_text(client, @params, ex)}")
    rescue ex : PluginHelpers::DockerClient::InvalidDockerHostError | Socket::ConnectError | Socket::Addrinfo::Error
      PluginResult.new(changed: false, failed: true, msg: PluginHelpers::DockerClient.connect_failure_text(ex, @params))
    end

    private def volume_settings : VolumeSettings
      VolumeSettings.new(
        name: @params["volume_name"]?.to_s,
        driver: @params["driver"]? || "local",
        driver_options: parse_dict_param("driver_options") || {} of String => JSON::Any,
        labels_given: !@params["labels"]?.nil? && !explicit_null_param?("labels"),
        recreate: @params["recreate"]? || "never",
        state: @params["state"]? || "present",
        check_mode: true?(@params["_ansible_check_mode"]?),
        debug_mode: true?(@params["debug"]?),
        diff_mode: true?(@params["_ansible_diff"]?),
      )
    end

    # Real's AnsibleDockerClientBase.__init__ asks the daemon for its API
    # version before DockerVolumeManager (and its get_existing_volume /
    # sanitize_labels calls) run, so an unreachable daemon fails here with
    # the connect wording, not with a label error.
    private def connect_volume_client : KrikriDocker::Client
      client, _ = PluginHelpers::DockerClient.build(@params)
      client.api_version
      client
    end

    # Real's argspec canonicalizes the `name` alias onto volume_name
    # before any validation or lookup; every other consumer in this
    # engine hands the plugin the spelling the playbook used.
    private def resolve_aliases : Nil
      return unless @params.has_key?("name")
      return if @params.has_key?("volume_name")
      @params["volume_name"] = @params["name"]
    end

    private def ensure_present(
      client : KrikriDocker::Client,
      settings : VolumeSettings,
      labels : Hash(String, JSON::Any),
      existing : JSON::Any?,
    ) : PluginResult
      actions = [] of String
      drift = existing ? has_different_config(existing, settings.driver, settings.driver_options, labels) : Drift.new
      before, after = drift_maps(drift, !existing.nil?)

      if existing && recreate_now?(drift, settings.recreate)
        remove_volume!(client, settings.name, settings.check_mode, actions)
        existing = nil
      end

      create_volume!(client, settings, labels, actions) unless existing

      result = PluginResult.new(changed: !actions.empty?, failed: false, failed_flag: false)
      result.key_order = KEY_ORDER
      # real pops `actions` again once a real (non-check, non-debug) run
      # finishes.
      result.extra["actions"] = json_string_array(actions) if settings.check_mode || settings.debug_mode
      result.extra["volume"] = find_volume(client, settings.name) || JSON::Any.new(nil)
      attach_present_diff(result, drift, before, after, settings)
      result
    end

    private def ensure_absent(client : KrikriDocker::Client, settings : VolumeSettings, existing : JSON::Any?) : PluginResult
      actions = [] of String
      existed_before = !existing.nil?

      if existing
        remove_volume!(client, settings.name, settings.check_mode, actions)
      end

      # absent() never records a `differences` key, and (unlike present)
      # keeps `actions` in the result outside check mode too.
      result = PluginResult.new(changed: !actions.empty?, failed: false, failed_flag: false)
      result.key_order = KEY_ORDER
      result.extra["actions"] = json_string_array(actions)
      if settings.diff_mode || settings.check_mode || settings.debug_mode
        diff = {} of String => JSON::Any
        if settings.diff_mode
          diff["before"] = JSON::Any.new({"exists" => JSON::Any.new(existed_before)} of String => JSON::Any)
          diff["after"] = JSON::Any.new({"exists" => JSON::Any.new(false)} of String => JSON::Any)
        end
        result.diff = JSON::Any.new(diff)
      end
      result
    end

    # Real opts into the delete-and-recreate path when the option to do so
    # is set and either the config drifted or `recreate: always` asks for
    # it unconditionally.
    private def recreate_now?(drift : Drift, recreate : String) : Bool
      return true if recreate == "always"
      !drift.empty? && recreate == "options-changed"
    end

    # present() records `exists` in the difference tracker first, so it
    # leads both the before/after maps, followed by the drift entries.
    private def drift_maps(drift : Drift, existed_before : Bool) : {Hash(String, JSON::Any), Hash(String, JSON::Any)}
      before = {"exists" => JSON::Any.new(existed_before)} of String => JSON::Any
      after = {"exists" => JSON::Any.new(true)} of String => JSON::Any
      drift.entries.each do |entry|
        before[entry.name] = entry.active || JSON::Any.new(nil)
        after[entry.name] = entry.parameter || JSON::Any.new(nil)
      end
      {before, after}
    end

    private def attach_present_diff(
      result : PluginResult,
      drift : Drift,
      before : Hash(String, JSON::Any),
      after : Hash(String, JSON::Any),
      settings : VolumeSettings,
    ) : Nil
      return unless settings.diff_mode || settings.check_mode || settings.debug_mode
      diff = {"differences" => json_string_array(drift.names)} of String => JSON::Any
      if settings.diff_mode
        diff["before"] = JSON::Any.new(before)
        diff["after"] = JSON::Any.new(after)
      end
      result.diff = JSON::Any.new(diff)
    end

    # Ansible's has_different_config(): only the fields real compares -
    # driver, driver_options (whole dict when the volume has none, per
    # key otherwise) and requested labels.
    private def has_different_config(
      existing : JSON::Any,
      driver : String,
      driver_options : Hash(String, JSON::Any),
      labels : Hash(String, JSON::Any),
    ) : Drift
      drift = Drift.new

      active_driver = existing["Driver"]?.try(&.as_s?)
      if !driver.empty? && active_driver != driver
        drift.add("driver", JSON::Any.new(driver), active_driver.try { |value| JSON::Any.new(value) })
      end

      unless driver_options.empty?
        active_options = existing["Options"]?.try(&.as_h?)
        if active_options.nil? || active_options.empty?
          drift.add("driver_options", JSON::Any.new(driver_options), nil)
        else
          driver_options.each do |key, value|
            active = active_options[key]?
            if active.nil? || falsey_json?(active) || active != value
              drift.add("driver_options.#{key}", value, active)
            end
          end
        end
      end

      unless labels.empty?
        active_labels = existing["Labels"]?.try(&.as_h?) || {} of String => JSON::Any
        labels.each do |key, value|
          active = active_labels[key]?
          next if active == value
          drift.add("labels.#{key}", value, active)
        end
      end

      drift
    end

    # Python truthiness of a JSON value, for real's `not
    # existing["Options"].get(key)` test.
    private def falsey_json?(value : JSON::Any) : Bool
      case raw = value.raw
      when Nil         then true
      when Bool        then !raw
      when Int64       then raw == 0
      when Float64     then raw == 0.0
      when String      then raw.empty?
      when Array, Hash then raw.empty?
      else                  true
      end
    end

    # Ansible's create_volume: the daemon payload always carries Name,
    # Driver and DriverOpts, and `Labels` only when the task gave the
    # option at all (an explicit null is real's None, not `{}`).
    private def create_volume!(
      client : KrikriDocker::Client,
      settings : VolumeSettings,
      labels : Hash(String, JSON::Any),
      actions : Array(String),
    ) : Nil
      unless settings.check_mode
        api = KrikriDocker::API.new(client)
        created = with_volume_api_failure(client) do
          api.volumes.create(settings.name, settings.driver, settings.driver_options, settings.labels_given ? labels : nil)
        end
        created_name = created["Name"]?.try(&.as_s?) || settings.name
        with_volume_api_failure(client) { api.volumes.get_json(created_name) }
      end
      actions << "Created volume #{settings.name} with driver #{settings.driver}"
    end

    private def remove_volume!(client : KrikriDocker::Client, name : String, check_mode : Bool, actions : Array(String)) : Nil
      with_volume_api_failure(client) { KrikriDocker::API.new(client).volumes.remove(name) } unless check_mode
      actions << "Removed volume #{name}"
    end

    # The volume entry from the daemon's own `GET /volumes` listing, the
    # same payload real registers as `volume` (an exact Name match; a
    # null/absent Volumes list means no volume exists).
    private def find_volume(client : KrikriDocker::Client, name : String) : JSON::Any?
      response = with_volume_api_failure(client) { KrikriDocker::API.new(client).volumes.list_json }
      volumes = response["Volumes"]?
      return nil if volumes.nil? || volumes.raw.nil?
      volumes.as_a.find { |volume| volume["Name"]?.try(&.as_s?) == name }
    end

    # Raised when a Docker API call answers with an error status: real's
    # get_existing_volume/create_volume/remove_volume all catch APIError
    # and call client.fail(to_text(e)), so the failure msg is the SDK's
    # own text with no "unexpected Docker error" prefix.
    class VolumeApiFailure < Exception
    end

    private def with_volume_api_failure(client : KrikriDocker::Client, &)
      yield
    rescue ex : KrikriDocker::Errors::DockerAPIError
      raise VolumeApiFailure.new(PluginHelpers::DockerSdkError.api_error_text(client, @params, ex))
    end

    # sanitize_labels(labels, "labels", client): real fails a bool/float
    # label value (Python bools and floats are not safely stringifiable
    # for the daemon) and stringifies everything else.
    private def sanitized_labels : Hash(String, JSON::Any) | PluginResult
      raw = @params["labels"]?
      return {} of String => JSON::Any unless raw

      parsed = parse_dict_values(raw)
      return {} of String => JSON::Any if parsed.nil?

      sanitized = {} of String => JSON::Any
      parsed.each do |key, value|
        case value.raw
        when Bool, Float64
          return PluginResult.new(changed: false, failed: true,
            msg: "The value #{python_repr(value)} for '#{key}' of labels is not a string or something than can be safely converted to a string!")
        when Nil
          sanitized[key] = JSON::Any.new("None")
        when Int64
          sanitized[key] = JSON::Any.new(value.as_i64.to_s)
        else
          sanitized[key] = value
        end
      end
      sanitized
    end

    private def python_repr(value : JSON::Any) : String
      case raw = value.raw
      when Bool then raw ? "True" : "False"
      else           raw.to_s
      end
    end

    # A dict-typed param as Ansible's check_type_dict leaves it: a JSON
    # object, or a list/pair-string of KEY=VALUE entries (Ansible accepts
    # all three shapes for dict options).
    private def parse_dict_param(param : String) : Hash(String, JSON::Any)?
      raw = @params[param]?
      raw.try { |value| parse_dict_values(value) }
    end

    private def parse_dict_values(raw : String) : Hash(String, JSON::Any)?
      if object = (JSON.parse(raw) rescue nil).try(&.as_h?)
        return object
      end
      if items = (JSON.parse(raw) rescue nil).try(&.as_a?)
        return items.each_with_object({} of String => JSON::Any) do |item, parsed|
          key, _, value = (item.as_s? || item.raw.to_s).partition('=')
          parsed[key] = JSON::Any.new(value)
        end
      end
      return nil unless raw.includes?("=")
      raw.split(',').each_with_object({} of String => JSON::Any) do |entry, parsed|
        key, _, value = entry.partition('=')
        parsed[key.strip] = JSON::Any.new(value.strip)
      end
    end

    private def json_string_array(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |value| JSON::Any.new(value) })
    end

    # AnsibleModule validation over the merged spec, in
    # arg_spec.ArgumentSpecValidator.validate order: required -> types ->
    # choices -> required_together -> unsupported. The daemon connection
    # only happens after all of it.
    private def validate_arguments : PluginResult?
      if err = validate_required
        return err
      end

      if err = validate_types
        return err
      end

      if err = validate_choices
        return err
      end

      if err = validate_required_together
        return err
      end

      validate_unsupported
    end

    private def validate_required : PluginResult?
      return nil if @params["volume_name"]?
      missing_required_error(["volume_name"])
    end

    private def validate_types : PluginResult?
      INT_PARAMS.each do |param|
        next unless raw = @params[param]?
        next if raw.to_i32?
        return int_type_error(param, raw)
      end
      BOOL_PARAMS.each do |param|
        next unless raw = @params[param]?
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      DICT_PARAMS.each do |param|
        next unless raw = @params[param]?
        if err = check_dict_type(param, raw)
          return err
        end
      end
      nil
    end

    # check_type_dict semantics for a top-level dict param (errors get
    # the parameters.py "argument ... is of type" wrapper).
    private def check_dict_type(param : String, raw : String) : PluginResult?
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Hash
        nil
      when Array
        value.each do |element|
          next if element.is_a?(String)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'list'> and we were unable to convert to dict: " \
                 "<class 'list'> cannot be converted to a dict")
        end
        nil
      else
        if err = check_dict_type_string(raw)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to dict: #{err.msg}")
        end
        nil
      end
    end

    # Bare check_type_dict: strings try JSON (when they look like
    # objects) then k1=v1,k2=v2 pairs; everything else fails.
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

    private def validate_choices : PluginResult?
      CHOICE_PARAMS.each do |param, allowed|
        value = @params[param]?
        next unless value
        next if allowed.includes?(value)
        return choices_error(param, allowed, value)
      end
      nil
    end

    # _util.py's DOCKER_REQUIRED_TOGETHER, shared by every API module.
    private def validate_required_together : PluginResult?
      has_cert = @params["client_cert"]? || @params["cert_path"]? || @params["tls_client_cert"]?
      has_key = @params["client_key"]? || @params["key_path"]? || @params["tls_client_key"]?
      if (has_cert || has_key) && !(has_cert && has_key)
        return required_together_error(PluginHelpers::DockerClient::COMMON_REQUIRED_TOGETHER)
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("community.docker.docker_volume", unsupported, SPEC)
    end

    # One has_different_config() entry: the option name, the requested
    # (`parameter`) and the volume's current (`active`) value.
    record DriftEntry, name : String, parameter : JSON::Any?, active : JSON::Any?

    class Drift
      getter entries = [] of DriftEntry

      def add(name : String, parameter : JSON::Any?, active : JSON::Any?) : Nil
        @entries << DriftEntry.new(name, parameter, active)
      end

      def empty? : Bool
        @entries.empty?
      end

      def names : Array(String)
        @entries.map(&.name)
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::DockerVolumePlugin.new(config)
plugin.run
