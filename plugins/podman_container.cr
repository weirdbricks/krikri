#!/usr/bin/env crystal
# containers.podman.podman_container - subset port (issue #1156).
#
# Ported here: the module's AnsibleModule argument-validation surface
# (containers.podman 1.17.0's ARGUMENTS_SPEC_CONTAINER, the release real
# ansible resolves on the round controllers), main()'s pre-state
# "required image" check, and PodmanManager.__init__'s
# get_bin_path(executable, required=True) probe - the probe is the FIRST
# thing the module does for every state, check mode or not, so a host
# without podman fails the task with
# `Failed to find required executable "podman" in paths: ...` exactly
# like real (that failure is the whole observable surface of round
# 29906951's thulium_drake.gitea_runner divergence, which this engine
# used to show as a graceful unavailable-module "skipping:" plus the
# end-of-run engine-limit exit 4).
#
# NOT ported (returns a plain ok/changed=false after a successful
# probe, see KNOWN_MISSING.md): the actual container management behind
# every state and the quadlet unit-file generation - real drives `podman`
# and writes /etc/containers/systemd/*.container files, which needs a
# real podman host and its own result shapes. On a host where the probe
# succeeds krikri therefore reports ok where real reports changed/ok
# from real container work.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"

module Krikri
  class PodmanContainerPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Ansible's argument_spec (podman_container_lib 1.17.0
    # ARGUMENTS_SPEC_CONTAINER), name => aliases, in declaration order.
    SPEC = {
      "name"                       => %w[],
      "executable"                 => %w[],
      "state"                      => %w[],
      "image"                      => %w[],
      "annotation"                 => %w[],
      "arch"                       => %w[],
      "attach"                     => %w[],
      "authfile"                   => %w[],
      "blkio_weight"               => %w[],
      "blkio_weight_device"        => %w[],
      "cap_add"                    => %w[capabilities],
      "cap_drop"                   => %w[],
      "cgroup_conf"                => %w[],
      "cgroup_parent"              => %w[],
      "cgroupns"                   => %w[],
      "cgroups"                    => %w[],
      "chrootdirs"                 => %w[],
      "cidfile"                    => %w[],
      "cmd_args"                   => %w[],
      "conmon_pidfile"             => %w[],
      "command"                    => %w[],
      "cpu_period"                 => %w[],
      "cpu_quota"                  => %w[],
      "cpu_rt_period"              => %w[],
      "cpu_rt_runtime"             => %w[],
      "cpu_shares"                 => %w[],
      "cpus"                       => %w[],
      "cpuset_cpus"                => %w[],
      "cpuset_mems"                => %w[],
      "decryption_key"             => %w[],
      "delete_depend"              => %w[],
      "delete_time"                => %w[],
      "delete_volumes"             => %w[],
      "detach"                     => %w[],
      "debug"                      => %w[],
      "detach_keys"                => %w[],
      "device"                     => %w[],
      "device_cgroup_rule"         => %w[],
      "device_read_bps"            => %w[],
      "device_read_iops"           => %w[],
      "device_write_bps"           => %w[],
      "device_write_iops"          => %w[],
      "dns"                        => %w[dns_servers],
      "dns_option"                 => %w[dns_opts],
      "dns_search"                 => %w[dns_search_domains],
      "entrypoint"                 => %w[],
      "env"                        => %w[],
      "env_file"                   => %w[env_files],
      "env_host"                   => %w[],
      "env_merge"                  => %w[],
      "etc_hosts"                  => %w[add_hosts],
      "expose"                     => %w[exposed exposed_ports],
      "force_restart"              => %w[restart],
      "force_delete"               => %w[],
      "generate_systemd"           => %w[],
      "gidmap"                     => %w[],
      "gpus"                       => %w[],
      "group_add"                  => %w[groups],
      "group_entry"                => %w[],
      "healthcheck"                => %w[health_cmd],
      "healthcheck_interval"       => %w[health_interval],
      "healthcheck_retries"        => %w[health_retries],
      "healthcheck_start_period"   => %w[health_start_period],
      "health_startup_cmd"         => %w[],
      "health_startup_interval"    => %w[],
      "health_startup_retries"     => %w[],
      "health_startup_success"     => %w[],
      "health_startup_timeout"     => %w[],
      "healthcheck_timeout"        => %w[health_timeout],
      "healthcheck_failure_action" => %w[health_on_failure],
      "hooks_dir"                  => %w[],
      "hostname"                   => %w[],
      "hostuser"                   => %w[],
      "http_proxy"                 => %w[],
      "image_volume"               => %w[],
      "image_strict"               => %w[],
      "init"                       => %w[],
      "init_ctr"                   => %w[],
      "init_path"                  => %w[],
      "interactive"                => %w[],
      "ip"                         => %w[],
      "ip6"                        => %w[],
      "ipc"                        => %w[ipc_mode],
      "kernel_memory"              => %w[],
      "label"                      => %w[labels],
      "label_file"                 => %w[],
      "log_driver"                 => %w[],
      "log_level"                  => %w[],
      "log_opt"                    => %w[log_options],
      "mac_address"                => %w[],
      "memory"                     => %w[],
      "memory_reservation"         => %w[],
      "memory_swap"                => %w[],
      "memory_swappiness"          => %w[],
      "mount"                      => %w[mounts],
      "network"                    => %w[net network_mode],
      "network_aliases"            => %w[network_alias],
      "no_healthcheck"             => %w[],
      "no_hosts"                   => %w[],
      "oom_kill_disable"           => %w[],
      "oom_score_adj"              => %w[],
      "os"                         => %w[],
      "passwd"                     => %w[],
      "passwd_entry"               => %w[],
      "personality"                => %w[],
      "pid"                        => %w[pid_mode],
      "pid_file"                   => %w[],
      "pids_limit"                 => %w[],
      "platform"                   => %w[],
      "pod"                        => %w[],
      "pod_id_file"                => %w[],
      "preserve_fd"                => %w[],
      "preserve_fds"               => %w[],
      "privileged"                 => %w[],
      "publish"                    => %w[ports published published_ports],
      "publish_all"                => %w[],
      "pull"                       => %w[],
      "quadlet_dir"                => %w[],
      "quadlet_filename"           => %w[],
      "quadlet_file_mode"          => %w[],
      "quadlet_options"            => %w[],
      "rdt_class"                  => %w[],
      "read_only"                  => %w[],
      "read_only_tmpfs"            => %w[],
      "recreate"                   => %w[],
      "requires"                   => %w[],
      "restart_policy"             => %w[],
      "restart_time"               => %w[],
      "retry"                      => %w[],
      "retry_delay"                => %w[],
      "rm"                         => %w[remove auto_remove],
      "rmi"                        => %w[],
      "rootfs"                     => %w[],
      "seccomp_policy"             => %w[],
      "secrets"                    => %w[],
      "sdnotify"                   => %w[],
      "security_opt"               => %w[],
      "shm_size"                   => %w[],
      "shm_size_systemd"           => %w[],
      "sig_proxy"                  => %w[],
      "stop_signal"                => %w[],
      "stop_timeout"               => %w[],
      "stop_time"                  => %w[],
      "subgidname"                 => %w[],
      "subuidname"                 => %w[],
      "sysctl"                     => %w[],
      "systemd"                    => %w[],
      "timeout"                    => %w[],
      "timezone"                   => %w[],
      "tls_verify"                 => %w[],
      "tmpfs"                      => %w[],
      "tty"                        => %w[],
      "uidmap"                     => %w[],
      "ulimit"                     => %w[ulimits],
      "umask"                      => %w[],
      "unsetenv"                   => %w[],
      "unsetenv_all"               => %w[],
      "user"                       => %w[],
      "userns"                     => %w[userns_mode],
      "uts"                        => %w[],
      "variant"                    => %w[],
      "volume"                     => %w[volumes],
      "volumes_from"               => %w[],
      "workdir"                    => %w[working_dir],
    }

    # log_opt declares suboptions (real arg-spec `options:`), so a
    # non-dict value dies in the element pass with the BARE
    # check_type_dict wording (see podman_image's build/push_args), and
    # its sub-keys are spec-valid in the unsupported-params check.
    SUBOPTION_DICT_PARAMS = %w[log_opt]
    SUBOPTION_KEYS        = {"log_opt" => %w[max_size path tag]}

    # The type-converted params, in ARGUMENTS_SPEC_CONTAINER declaration
    # order: real's _validate_argument_types walks the whole spec in
    # this order and only ever surfaces the FIRST failure, so the order
    # decides which error a multi-invalid task reports.
    TYPED_PARAMS = {
      {"annotation", "dict"},
      {"blkio_weight", "int"},
      {"blkio_weight_device", "dict"},
      {"cgroup_conf", "dict"},
      {"cpu_period", "int"},
      {"cpu_quota", "int"},
      {"cpu_rt_period", "int"},
      {"cpu_rt_runtime", "int"},
      {"cpu_shares", "int"},
      {"delete_depend", "bool"},
      {"delete_volumes", "bool"},
      {"detach", "bool"},
      {"debug", "bool"},
      {"env", "dict"},
      {"env_host", "bool"},
      {"env_merge", "dict"},
      {"etc_hosts", "dict"},
      {"force_restart", "bool"},
      {"force_delete", "bool"},
      {"generate_systemd", "dict"},
      {"healthcheck_retries", "int"},
      {"health_startup_retries", "int"},
      {"health_startup_success", "int"},
      {"http_proxy", "bool"},
      {"image_strict", "bool"},
      {"init", "bool"},
      {"interactive", "bool"},
      {"label", "dict"},
      {"log_opt", "dict"},
      {"memory_swappiness", "int"},
      {"no_healthcheck", "bool"},
      {"no_hosts", "bool"},
      {"oom_kill_disable", "bool"},
      {"oom_score_adj", "int"},
      {"privileged", "bool"},
      {"publish_all", "bool"},
      {"read_only", "bool"},
      {"read_only_tmpfs", "bool"},
      {"recreate", "bool"},
      {"retry", "int"},
      {"rm", "bool"},
      {"rmi", "bool"},
      {"rootfs", "bool"},
      {"sig_proxy", "bool"},
      {"stop_signal", "int"},
      {"stop_timeout", "int"},
      {"sysctl", "dict"},
      {"timeout", "int"},
      {"tls_verify", "bool"},
      {"tmpfs", "dict"},
      {"tty", "bool"},
      {"unsetenv_all", "bool"},
    }

    # main()'s state handling map, only the str+choices members.
    STATE_CHOICES          = %w[absent present stopped started created quadlet]
    HEALTH_FAILURE_CHOICES = %w[none kill restart stop]
    IMAGE_VOLUME_CHOICES   = %w[bind tmpfs ignore]
    INIT_CTR_CHOICES       = %w[once always]
    LOG_DRIVER_CHOICES     = %w[k8s-file journald json-file]
    LOG_LEVEL_CHOICES      = %w[debug info warn error fatal panic]
    PULL_CHOICES           = %w[always missing never newer]
    ATTACH_CHOICES         = %w[stdout stderr stdin]

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      state = @params["state"]?.presence || "started"
      # main()'s pre-PodmanManager check: present/created demand an
      # image unless a forced restart of an existing container is meant.
      if %w[present created].includes?(state) && !true?(@params["force_restart"]?) && @params["image"]?.presence.nil?
        return PluginResult.new(changed: false, failed: true,
          msg: "State '#{state}' required image to be configured!")
      end

      # PodmanManager.__init__: get_bin_path(executable, required=True)
      # runs for EVERY state before any container/quadlet work, check
      # mode included - a host without the binary fails here in real,
      # and that failure is the byte-comparable surface this port
      # guarantees (same probe shape as podman_image's).
      executable = @params["executable"]?.presence || "podman"
      bin_ok = remote_exec("command -v #{Shell.quote_arg(executable)}", force_shell: true)
      return PluginResult.new(changed: false, failed: true,
        msg: missing_executable_message(executable)) if bin_ok[:exit_code] != 0

      # Post-probe surface unported (see header): every state's real
      # work reports a plain ok here.
      PluginResult.new(changed: false, failed: false)
    end

    # AnsibleModule validation, in arg_spec.ArgumentSpecValidator
    # validate order: mutually_exclusive -> required -> types
    # (declaration order) -> choices -> unsupported. All of it precedes
    # the podman executable probe in real, so it is the byte-comparable
    # surface when no podman binary exists on the target.
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

      validate_unsupported
    end

    private def validate_mutually_exclusive : PluginResult?
      return nil unless present_with_alias?("no_hosts") && present_with_alias?("etc_hosts")
      PluginResult.new(changed: false, failed: true,
        msg: "parameters are mutually exclusive: no_hosts|etc_hosts")
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
      TYPED_PARAMS.each do |(param, kind)|
        next unless raw = @params[param]?
        case kind
        when "bool"
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        when "int"
          next if int_convertible?(raw)
          return int_type_error(param, raw)
        when "dict"
          if err = check_dict_type(param, raw)
            return err
          end
        end
      end
      SUBOPTION_DICT_PARAMS.each do |param|
        next unless raw = @params[param]?
        if err = check_suboption_dict_type(param, raw)
          return err
        end
      end
      nil
    end

    # check_type_int on the wire's string form: Python int() accepts
    # optional sign/whitespace and nothing else.
    private def int_convertible?(raw : String) : Bool
      !!raw.strip.match(/^[+-]?\d+$/)
    end

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
      str_choice_specs = {
        "state"                      => STATE_CHOICES,
        "healthcheck_failure_action" => HEALTH_FAILURE_CHOICES,
        "image_volume"               => IMAGE_VOLUME_CHOICES,
        "init_ctr"                   => INIT_CTR_CHOICES,
        "log_driver"                 => LOG_DRIVER_CHOICES,
        "log_level"                  => LOG_LEVEL_CHOICES,
        "pull"                       => PULL_CHOICES,
      }
      str_choice_specs.each do |param, allowed|
        next unless raw = @params[param]?
        next if allowed.includes?(raw)
        return choices_error(param, allowed, raw)
      end
      # attach is a list of choices: each element is checked.
      if raw = @params["attach"]?
        parse_sub_list(raw).each do |element|
          value = element.as_s?
          next if value.nil? || ATTACH_CHOICES.includes?(value)
          return choices_error("attach", ATTACH_CHOICES, value)
        end
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC, SUBOPTION_KEYS)
      return nil if unsupported.empty?
      unsupported_params_error("containers.podman.podman_container", unsupported, SPEC)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PodmanContainerPlugin.new(config)
plugin.run
