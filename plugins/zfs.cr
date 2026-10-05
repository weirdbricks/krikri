#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/zfs_commands"

module Krikri
  # zfs plugin (community.general.zfs) - manages ZFS filesystems,
  # volumes and snapshots through the `zfs` CLI, mirroring the real
  # module's Zfs class. Params:
  # - name: required. Dataset/volume/snapshot name (rpool/myfs,
  #   rpool/myvol, rpool/myfs@snap).
  # - state: required. present / absent.
  # - origin: snapshot to clone from (state=present only; mutually
  #   exclusive with a snapshot name).
  # - extra_zfs_properties: dict of zfs properties (volsize ->
  #   -V, volblocksize -> -b, everything else -o k=v at create time;
  #   `zfs set` on an existing dataset). Python-style bools are
  #   normalized to on/off like the Ansible module.
  #
  # Idempotency: present against an existing dataset compares each
  # requested property's current value (via `zfs get`) and only sets
  # the ones that differ; absent destroys with -R only when the
  # dataset exists. Creation-only properties (e.g. volblocksize) on an
  # already-existing dataset behave like the Ansible module: they compare
  # against '-'-sourced values and `zfs set` fails on them if they
  # actually differ.
  #
  # Not implemented: the Solaris-enhanced-sharing property aliasing
  # (share.nfs/share.smb) - every target host this benchmarks against
  # runs OpenZFS on Linux, where the plain spellings apply.
  class ZfsPlugin < BasePlugin
    # The registered success shape (round 992003 kop_storage captures):
    # exit_json(**result) with result built as dict(name=, state=), then
    # diff, then the extra_zfs_properties, then changed - [name, state,
    # diff, ..., changed, failed]. The Ansible module never passes msg on a
    # success exit.
    private ZFS_KEY_ORDER_BASE = %w[name state diff]

    # Ansible's fail_json kwargs (cmd, rc, stdout, stderr - basic.py's
    # run_command(check_rc=True) failure) lead the registered result,
    # then failed/msg, then the stdout_lines/stderr_lines basic.py
    # derives, then changed/exception (round 992003 zfs_fail).
    private ZFS_FAIL_KEY_ORDER = %w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception]

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      name = @params["name"]?
      state = @params["state"]?

      # AnsibleModule construction - required args (name and
      # state, sorted) and the state choices fire here, before the
      # origin check and the zfs/zpool binary lookup below.
      missing = ["name", "state"].select { |arg| arg == "name" ? !name : !state }
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: #{missing.join(", ")}") unless missing.empty?
      unless name && state
        return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: #{missing.join(", ")}")
      end
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: absent, present, got: #{state}")
      end

      origin = @params["origin"]?.try { |origin| origin.empty? ? nil : origin }
      properties = parse_properties
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Ansible's main() runs this check before Zfs.__init__ does the
      # binary lookup, so origin-on-snapshot wins even on a host
      # without the zfs binaries.
      if origin && name.includes?('@')
        return PluginResult.new(changed: false, failed: true, msg: "cannot specify origin when operating on a snapshot")
      end

      # The Ansible module resolves both binaries with
      # get_bin_path(required=True) up front and fails with this exact
      # wording when either is absent - kept identical so a non-ZFS
      # host fails the task with Ansible's message instead of a
      # FileNotFoundError from spawning a missing binary.
      ["zfs", "zpool"].each do |binary|
        unless executable_in_path?(binary)
          return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable \"#{binary}\" in paths: #{ENV.fetch("PATH", "")}")
        end
      end

      changed = false
      # Real builds result = dict(name=, state=) first, then assigns
      # diff, then update(extra_zfs_properties), then changed - that
      # insertion order is the registered key order.
      if state == "present"
        if exists?(name)
          diff = {"before" => JSON::Any.new({"extra_zfs_properties" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any),
                  "after"  => JSON::Any.new({"extra_zfs_properties" => JSON::Any.new({} of String => JSON::Any)} of String => JSON::Any)}
          properties.each do |prop, value|
            current = property_value(name, prop, list_properties(name))
            next if current == value
            changed = true
            diff["before"].as_h["extra_zfs_properties"].as_h[prop] = current ? JSON::Any.new(current) : JSON::Any.new(nil)
            diff["after"].as_h["extra_zfs_properties"].as_h[prop] = JSON::Any.new(value)
            if failure = set_property(name, prop, value, check_mode)
              return failure
            end
          end
          diff["before_header"] = JSON::Any.new(name)
          diff["after_header"] = JSON::Any.new(name)
          res = success_result(name, state, JSON::Any.new(diff), properties, changed)
        else
          changed = true
          diff = JSON.parse({
            "before" => {"state" => "absent"},
            "after"  => {"state" => state},
          }.to_json).as_h
          diff["before_header"] = JSON::Any.new(name)
          diff["after_header"] = JSON::Any.new(name)
          cmd = Krikri::PluginHelpers::ZfsCommands.create_command(name, properties, origin)
          return PluginResult.new(changed: false, failed: true, msg: "cannot specify origin when operating on a snapshot") unless cmd
          if failure = run!(zfs_path, cmd, "create #{name}", check_mode)
            return failure
          end
          res = success_result(name, state, JSON::Any.new(diff), properties, true)
        end
      elsif exists?(name)
        diff = JSON.parse({
          "before" => {"state" => "present"},
          "after"  => {"state" => "absent"},
        }.to_json).as_h
        diff["before_header"] = JSON::Any.new(name)
        diff["after_header"] = JSON::Any.new(name)
        changed = true
        if failure = run!(zfs_path, Krikri::PluginHelpers::ZfsCommands.destroy_command(name), "destroy #{name}", check_mode)
          return failure
        end
        res = success_result(name, state, JSON::Any.new(diff), properties, true)
      else
        # real: result["diff"] = {} (still gets the before/after headers
        # assigned onto it)
        diff = JSON.parse("{}").as_h
        diff["before_header"] = JSON::Any.new(name)
        diff["after_header"] = JSON::Any.new(name)
        res = success_result(name, state, JSON::Any.new(diff), properties, false)
      end

      res
    end

    # The single success exit shape: [name, state, diff, <properties...>,
    # changed] (+ the controller's failed backfill).
    private def success_result(name : String, state : String, diff : JSON::Any, properties : Hash(String, String), changed : Bool) : PluginResult
      res = PluginResult.new(changed: changed, failed: false)
      res.extra["name"] = JSON::Any.new(name)
      res.extra["state"] = JSON::Any.new(state)
      res.extra["diff"] = diff
      properties.each do |prop, value|
        res.extra[prop] = JSON::Any.new(value)
      end
      res.key_order = ZFS_KEY_ORDER_BASE + properties.keys + ["changed"]
      res
    end

    private def zfs_path : String
      binary_path("zfs")
    end

    # Real get_bin_path resolution - the full path as the module would
    # echo it in a failure's cmd kwarg.
    private def binary_path(binary : String) : String
      ENV.fetch("PATH", "").split(':').each do |dir|
        exe = File.join(dir, binary)
        return exe if File.exists?(exe) && File::Info.executable?(exe)
      end
      binary
    end

    private def executable_in_path?(binary : String) : Bool
      ENV.fetch("PATH", "").split(':').any? do |dir|
        exe = File.join(dir, binary)
        File.exists?(exe) && File::Info.executable?(exe)
      end
    end

    private def parse_properties : Hash(String, String)
      raw = @params["extra_zfs_properties"]?
      return {} of String => String unless raw && !raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.as_h.each_with_object(Hash(String, String).new) do |(key, value), result|
        rendered = Krikri::PluginHelpers::ZfsCommands.normalize_value(value)
        # `{{ x | default(omit) }}` inside a dict-typed param can only
        # be blanked to "" by the executor's post-substitution pass (an
        # omit can't drop a key that is part of a larger value) - an
        # empty rendered value is that blanked omit, never a real ZFS
        # property (ZFS properties are set/unset by value, and "" is
        # valid for none of them), so it means "not requested".
        next if rendered.empty?
        result[key] = rendered
      end
    rescue JSON::ParseException
      raise "invalid extra_zfs_properties: #{raw}"
    end

    private def exists?(name : String) : Bool
      cmd = Krikri::PluginHelpers::ZfsCommands.exists_command(name)
      Process.run(cmd[0], cmd[1..], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    end

    private def list_properties(name : String) : Array(String)
      output = IO::Memory.new
      cmd = Krikri::PluginHelpers::ZfsCommands.list_properties_command(name)
      status = Process.run(cmd[0], cmd[1..], output: output, error: Process::Redirect::Close)
      return [] of String unless status.success?
      Krikri::PluginHelpers::ZfsCommands.parse_list_properties(output.to_s)
    end

    private def property_value(name : String, prop : String, known : Array(String)) : String?
      return nil unless known.includes?(prop)
      output = IO::Memory.new
      cmd = Krikri::PluginHelpers::ZfsCommands.property_value_command(name, prop)
      status = Process.run(cmd[0], cmd[1..], output: output, error: Process::Redirect::Close)
      return nil unless status.success?
      value = output.to_s.chomp
      value.empty? ? nil : value
    end

    private def set_property(name : String, prop : String, value : String, check_mode : Bool) : PluginResult?
      return nil if check_mode
      run!(zfs_path, Krikri::PluginHelpers::ZfsCommands.set_property_command(name, prop, value), "set property #{prop}", false)
    end

    # Runs a zfs command; in check mode it is a no-op (Ansible's Zfs class
    # guards every mutating method). On failure, returns the registered
    # failure shape Ansible's run_command(check_rc=True) produces:
    # fail_json(cmd=..., rc=..., stdout=..., stderr=...) with msg = the
    # rstripped stderr (round 992003 zfs_fail capture).
    private def run!(zfs_path : String, cmd : Array(String), what : String, check_mode : Bool) : PluginResult?
      return nil if check_mode

      full = [zfs_path] + cmd[1..]
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(full[0], full[1..], output: stdout, error: stderr)
      return nil if status.success?

      out_text = stdout.to_s
      err = stderr.to_s
      PluginResult.new(
        changed: false,
        failed: true,
        msg: err.rstrip,
        cmd: full.join(' '),
        rc: status.exit_code || 1,
        stdout: out_text,
        stderr: err,
        stdout_lines: out_text.split('\n').reject(&.empty?),
        stderr_lines: err.split('\n').reject(&.empty?),
        key_order: ZFS_FAIL_KEY_ORDER,
      )
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::ZfsPlugin.new(config)
plugin.run
