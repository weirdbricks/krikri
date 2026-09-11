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
  #   normalized to on/off like the real module.
  #
  # Idempotency: present against an existing dataset compares each
  # requested property's current value (via `zfs get`) and only sets
  # the ones that differ; absent destroys with -R only when the
  # dataset exists. Creation-only properties (e.g. volblocksize) on an
  # already-existing dataset behave like the real module: they compare
  # against '-'-sourced values and `zfs set` fails on them if they
  # actually differ.
  #
  # Not implemented: the Solaris-enhanced-sharing property aliasing
  # (share.nfs/share.smb) - every target host this benchmarks against
  # runs OpenZFS on Linux, where the plain spellings apply.
  class ZfsPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing("name") unless name

      state = @params["state"]?
      return missing("state") unless state
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: present, absent, got #{state}")
      end

      origin = @params["origin"]?.try { |o| o.empty? ? nil : o }
      properties = parse_properties

      # The real module resolves both binaries with
      # get_bin_path(required=True) up front and fails with this exact
      # wording when either is absent - kept identical so a non-ZFS
      # host fails the task with real Ansible's message instead of a
      # FileNotFoundError from spawning a missing binary.
      ["zfs", "zpool"].each do |binary|
        unless executable_in_path?(binary)
          return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable #{binary} in paths: #{ENV.fetch("PATH", "")}")
        end
      end

      if origin && name.includes?('@')
        return PluginResult.new(changed: false, failed: true, msg: "cannot specify origin when operating on a snapshot")
      end

      changed = false
      if state == "present"
        if exists?(name)
          properties.each do |prop, value|
            current = property_value(name, prop, list_properties(name))
            next if current == value
            changed = true
            run!(Krikri::PluginHelpers::ZfsCommands.set_property_command(name, prop, value), "set property #{prop}")
          end
        else
          cmd = Krikri::PluginHelpers::ZfsCommands.create_command(name, properties, origin)
          return PluginResult.new(changed: false, failed: true, msg: "cannot specify origin when operating on a snapshot") unless cmd
          changed = true
          run!(cmd, "create #{name}")
        end
      elsif exists?(name)
        changed = true
        run!(Krikri::PluginHelpers::ZfsCommands.destroy_command(name), "destroy #{name}")
      end

      res = PluginResult.new(changed: changed, failed: false, msg: "name #{name}")
      res.extra["name"] = JSON::Any.new(name)
      res.extra["state"] = JSON::Any.new(state)
      properties.each do |prop, value|
        res.extra[prop] = JSON::Any.new(value)
      end
      res
    end

    private def missing(arg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "missing required argument: #{arg}")
    end

    private def executable_in_path?(binary : String) : Bool
      ENV.fetch("PATH", "").split(':').any? do |dir|
        exe = File.join(dir, binary)
        File.exists?(exe) && File.executable?(exe)
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

    private def run!(cmd : Array(String), what : String) : Nil
      output = IO::Memory.new
      status = Process.run(cmd[0], cmd[1..], output: output, error: output)
      unless status.success?
        raise "#{what} failed: #{output.to_s.strip}"
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::ZfsPlugin.new(config)
plugin.run
