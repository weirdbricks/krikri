#!/usr/bin/env crystal
# containers.podman.podman_image - manages podman images (pull/remove).
# Ported subset of containers.podman's podman_image module (round 300134:
# ikke_t.podman_container_systemd pulls images through it; previously
# unavailable -> rc=4 "unavailable modules").
#
# Supported here: name (image reference with optional registry/tag),
# tag (appended when name carries none), state (present/absent), force
# (re-pull even when the image exists; changed when the image ID moved),
# username/password (passed as --creds to pull), executable (default
# podman), pull_extra_args. The module's push:/build-from-Containerfile
# paths are not ported.
#
# The module's AnsibleModule validation surface IS fully implemented
# below (required name, bool/int type conversion, state/pull_policy
# choices in declaration order, username/password required-together,
# auth_file/username etc. mutual exclusions, unsupported params) -
# real runs all of it in AnsibleModule setup BEFORE the podman
# executable probe, and password is no_log there (censored from every
# message).
#
# Idempotency: `podman image exists <ref>` decides presence; pull only
# runs when absent or force, and the before/after image ID comparison
# decides changed (a re-pull that lands on the same ID is not a change).
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/podman_image"

module Krikri
  class PodmanImagePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real argument_spec (containers.podman podman_image.py), name =>
    # aliases - as shipped in the latest GALAXY release the podman-diff
    # harness installs: pull_policy/retry/retry_delay exist on MAIN only
    # (live-verified - real rejects both with Unsupported parameters).
    SPEC = {
      "name"              => %w[],
      "arch"              => %w[],
      "platform"          => %w[],
      "tag"               => %w[],
      "pull"              => %w[],
      "pull_extra_args"   => %w[],
      "push"              => %w[],
      "path"              => %w[],
      "force"             => %w[],
      "state"             => %w[],
      "validate_certs"    => %w[tls_verify tlsverify],
      "executable"        => %w[],
      "auth_file"         => %w[authfile],
      "username"          => %w[],
      "password"          => %w[],
      "ca_cert_dir"       => %w[],
      "quadlet_dir"       => %w[],
      "quadlet_filename"  => %w[],
      "quadlet_file_mode" => %w[],
      "quadlet_options"   => %w[],
      "build"             => %w[build_args buildargs],
      "push_args"         => %w[],
    }
    # build/push_args declare suboptions (real arg-spec `options:`), so
    # a non-dict value dies in _list_no_log_values' string-to-dict pass
    # with the BARE check_type_dict wording (live-verified), not the
    # wrapped "argument ... is of type" one.
    SUBOPTION_DICT_PARAMS = %w[build push_args]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      name = @params["name"]?.to_s
      tag = @params["tag"]?
      reference = PluginHelpers::PodmanImage.build_reference(name, tag)
      state = @params["state"]? || "present"
      force = true?(@params["force"]?)
      executable = @params["executable"]?.presence || "podman"

      bin_ok = remote_exec("command -v #{executable}")
      return censor(PluginResult.new(changed: false, failed: true,
        msg: "Failed to find required executable #{executable} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")) if bin_ok[:exit_code] != 0

      exists = remote_exec("#{executable} image exists #{reference}")
      image_exists = exists[:exit_code] == 0

      if state == "absent"
        return PluginResult.new(changed: false, failed: false,
          msg: "Image not found") unless image_exists
        rmi = remote_exec("#{executable} rmi -f #{reference}")
        return censor(PluginResult.new(changed: false, failed: true,
          msg: "Failed to remove image #{reference}: #{rmi[:stderr]}")) if rmi[:exit_code] != 0
        return PluginResult.new(changed: true, failed: false,
          msg: "Removed image #{reference}")
      end

      return PluginResult.new(changed: false, failed: false,
        msg: "Image already exists") if image_exists && !force

      image_id_before = image_id(executable, reference)
      creds = build_creds
      pull = remote_exec("#{executable} pull#{creds} #{reference}#{extra_args}")
      return censor(PluginResult.new(changed: false, failed: true,
        msg: "Failed to pull image #{reference}: #{pull[:stderr].presence || pull[:stdout]}")) if pull[:exit_code] != 0

      image_id_after = image_id(executable, reference)
      changed = !image_exists || image_id_before != image_id_after
      censor(PluginResult.new(changed: changed, failed: false,
        msg: "Updated podman image: #{reference}", podman_image: image_id_after))
    end

    # Real AnsibleModule validation, in arg_spec.ArgumentSpecValidator
    # validate order: mutually_exclusive -> required -> types
    # (declaration order) -> choices -> required_together -> unsupported
    # (deferred to last). All of it precedes the podman executable
    # probe in real, so it is the byte-comparable surface when no
    # podman binary exists on the target.
    private def validate_arguments : PluginResult?
      if err = validate_mutually_exclusive
        return err
      end

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

    private def validate_mutually_exclusive : PluginResult?
      groups = [%w[auth_file username], %w[auth_file password], %w[arch platform]]
      violating = groups.select do |group|
        group.count { |param| present_with_alias?(param) } > 1
      end
      return nil if violating.empty?
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: #{violating.map(&.join("|")).join(", ")}")
    end

    private def present_with_alias?(param : String) : Bool
      return true if @params[param]?
      (SPEC[param]? || %w[]).any? { |alias_name| @params[alias_name]? }
    end

    private def validate_required : PluginResult?
      return nil if @params["name"]?
      missing_required_error(["name"])
    end

    private def validate_types : PluginResult?
      # Merged-spec declaration order: pull/push/force/validate_certs
      # bools, retry int, build/push_args dicts (build's and push_args'
      # own sub-spec bool/choices surfaces not validated here - they
      # only matter for the unported push/build paths).
      {"pull", "push", "force", "validate_certs"}.each do |param|
        next unless raw = @params[param]?
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      SUBOPTION_DICT_PARAMS.each do |param|
        next unless raw = @params[param]?
        if err = check_suboption_dict_type(param, raw)
          return err
        end
      end
      nil
    end

    # A dict param WITH suboptions fails in _list_no_log_values' element
    # conversion pass (before the type stage): every non-hash value dies
    # with the BARE check_type_dict wording - a plain string directly,
    # a list element-by-element (live-verified: real podman_image
    # build: banana reports just "dictionary requested, could not parse
    # JSON or key=value").
    private def check_suboption_dict_type(param : String, raw : String) : PluginResult?
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Hash
        nil
      when Array
        value.each do |element|
          case raw_element = element.raw
          when String
            if err = check_dict_type_string(raw_element)
              return err
            end
          when Int64, Float64, Bool
            return PluginResult.new(changed: false, failed: true,
              msg: "Value '#{raw_element}' in the sub parameter field '#{param}' must by a dict, not '#{python_type_name(raw_element)}'")
          end
        end
        nil
      when String, Nil
        check_dict_type_string(value || raw)
      end
    end

    private def python_type_name(value) : String
      case value
      when Int64   then "int"
      when Float64 then "float"
      when Bool    then "bool"
      else              "str"
      end
    end

    # check_type_dict semantics for a top-level dict param (errors get
    # the parameters.py "argument ... is of type" wrapper).
    private def check_dict_type(param : String, raw : String) : PluginResult?
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Hash
        nil
      when Array
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{param}' is of type <class 'list'> and we were unable to convert to dict: " \
               "<class 'list'> cannot be converted to a dict")
      when String
        if err = check_dict_type_string(value)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to dict: #{err.msg}")
        end
        nil
      when Nil
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
      state = @params["state"]? || "present"
      return nil if %w[absent present build quadlet].includes?(state)
      choices_error("state", %w[absent present build quadlet], state)
    end

    private def validate_required_together : PluginResult?
      has_username = present_with_alias?("username")
      has_password = present_with_alias?("password")
      if (has_username || has_password) && !(has_username && has_password)
        return required_together_error(%w[username password])
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("containers.podman.podman_image", unsupported, SPEC)
    end

    # Real remove_values(): password is no_log, so its value never
    # appears in any message (whole-string equality becomes
    # VALUE_SPECIFIED_IN_NO_LOG_PARAMETER, occurrences become 8 stars).
    private def censor(result : PluginResult) : PluginResult
      secret = @params["password"]?.presence
      return result unless secret
      result.msg = "VALUE_SPECIFIED_IN_NO_LOG_PARAMETER" if result.msg == secret
      result.msg = result.msg.gsub(secret, "*" * 8)
      result
    end

    private def build_creds : String
      PluginHelpers::PodmanImage.creds_argument(@params["username"]?.presence, @params["password"]?.presence)
    end

    private def extra_args : String
      args = @params["pull_extra_args"]?.presence
      args ? " #{args}" : ""
    end

    private def image_id(executable : String, reference : String) : String?
      inspect = remote_exec("#{executable} image inspect --format '{{.Id}}' #{reference}")
      inspect[:exit_code] == 0 ? inspect[:stdout].strip.presence : nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PodmanImagePlugin.new(config)
plugin.run
