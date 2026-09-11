#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/sefcontext_commands"

module Krikri
  # sefcontext plugin (community.general.sefcontext) - manages SELinux
  # file context mapping definitions via the `semanage fcontext` CLI,
  # the same tool the real module's libsemanage binding drives.
  # Params (real module's argument spec):
  # - target: required (alias path). The path expression.
  # - setype: SELinux type. Required for state=present unless
  #   substitute: is given; mutually exclusive with it.
  # - substitute (alias equal): path-equivalence target; mutually
  #   exclusive with setype/seuser/selevel and ignored ftype.
  # - ftype: one of a/b/c/d/f/l/p/s, default "a" (all files).
  # - seuser: default system_u on add, existing value on modify.
  # - selevel (alias serange): default s0 on add, existing on modify.
  # - state: present (default) / absent.
  # - reload: accepted for compatibility (the CLI reloads the running
  #   policy on every commit; there is no way to suppress that from
  #   `semanage`).
  # - ignore_selinux_state: skip the getenforce pre-check.
  #
  # The real module never relabels existing files (its own documented
  # note) - a mapping change is persistent policy only, and idempotency
  # compares the exact (target, ftype) record's type/user/range.
  class SefcontextPlugin < BasePlugin
    def execute : PluginResult
      target = @params["target"]? || @params["path"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: target") unless target

      setype = @params["setype"]?
      substitute = @params["substitute"]? || @params["equal"]?
      ftype = @params["ftype"]? || "a"
      seuser = @params["seuser"]?
      serange = @params["selevel"]? || @params["serange"]?
      state = @params["state"]? || "present"
      ignore_selinux_state = true?(@params["ignore_selinux_state"]?)
      check_mode = true?(@params["check_mode"]?)

      unless Krikri::PluginHelpers::SefcontextCommands::FILE_TYPE_STR.has_key?(ftype)
        return PluginResult.new(changed: false, failed: true, msg: "value of ftype must be one of: a, b, c, d, f, l, p, s, got #{ftype}")
      end
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: present, absent, got #{state}")
      end
      if setype && substitute
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: setype|substitute")
      end
      if substitute && (@params["seuser"]? || @params["selevel"]? || @params["serange"]? || @params["ftype"]?)
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: substitute|ftype|seuser|selevel")
      end
      if state == "present" && !setype && !substitute
        return PluginResult.new(changed: false, failed: true, msg: "one of the following is required: setype, substitute")
      end

      unless ignore_selinux_state
        enforce = remote_exec("getenforce")
        if enforce[:exit_code] != 0 || enforce[:stdout].strip.downcase == "disabled"
          return PluginResult.new(changed: false, failed: true, msg: "SELinux is disabled on this host.")
        end
      end

      if substitute
        return manage_substitute(target, substitute, state, check_mode)
      end
      manage_fcontext(target, ftype, setype, seuser, serange, state, check_mode)
    end

    private def manage_substitute(target : String, substitute : String, state : String, check_mode : Bool) : PluginResult
      rc, listing, err = capture_semanage(["semanage", "fcontext", "-C", "-l"])
      return PluginResult.new(changed: false, failed: true, msg: "Failed to list SELinux file context substitutions: #{err.strip}") unless rc == 0

      existing = Krikri::PluginHelpers::SefcontextCommands.parse_equivalences(listing)[target]?
      if state == "absent"
        return PluginResult.new(changed: false, failed: false, msg: "") unless existing
        run!(["semanage", "fcontext", "-d", target], "delete SELinux file context substitution", check_mode)
        return PluginResult.new(changed: true, failed: false, msg: "")
      end

      return PluginResult.new(changed: false, failed: false, msg: "") if existing == substitute
      modify = !existing.nil?
      run!(Krikri::PluginHelpers::SefcontextCommands.add_equal_command(target, substitute, modify),
        "#{modify ? "modify" : "add"} SELinux file context substitution", check_mode)

      res = PluginResult.new(changed: true, failed: false, msg: "")
      res.extra["target"] = JSON::Any.new(target)
      res.extra["substitute"] = JSON::Any.new(substitute)
      res
    end

    private def manage_fcontext(target : String, ftype : String, setype : String?, seuser : String?, serange : String?, state : String, check_mode : Bool) : PluginResult
      rc, listing, err = capture_semanage(["semanage", "fcontext", "-l"])
      return PluginResult.new(changed: false, failed: true, msg: "Failed to list SELinux file context mappings: #{err.strip}") unless rc == 0

      ftype_str = Krikri::PluginHelpers::SefcontextCommands::FILE_TYPE_STR[ftype]
      existing = Krikri::PluginHelpers::SefcontextCommands.parse_listing(listing).find do |record|
        record.target == target && record.ftype_str == ftype_str
      end

      if state == "absent"
        return PluginResult.new(changed: false, failed: false, msg: "") unless existing
        run!(Krikri::PluginHelpers::SefcontextCommands.delete_command(target, ftype),
          "delete SELinux file context mapping", check_mode)
        return PluginResult.new(changed: true, failed: false, msg: "")
      end

      orig_seuser, orig_setype, orig_serange = existing ? split_context(existing.context) : {nil, nil, nil}
      eff_seuser = seuser || orig_seuser || "system_u"
      eff_serange = serange || orig_serange || "s0"
      eff_setype = setype.not_nil!

      if existing && eff_setype == orig_setype && eff_seuser == orig_seuser && eff_serange == orig_serange
        return PluginResult.new(changed: false, failed: false, msg: "")
      end

      if existing
        run!(Krikri::PluginHelpers::SefcontextCommands.modify_command(target, eff_setype, ftype, eff_seuser, eff_serange),
          "modify SELinux file context mapping", check_mode)
      else
        run!(Krikri::PluginHelpers::SefcontextCommands.add_command(target, eff_setype, ftype, eff_seuser, eff_serange),
          "add SELinux file context mapping", check_mode)
      end

      res = PluginResult.new(changed: true, failed: false, msg: "")
      res.extra["target"] = JSON::Any.new(target)
      res.extra["ftype"] = JSON::Any.new(ftype)
      res.extra["setype"] = JSON::Any.new(eff_setype)
      res.extra["seuser"] = JSON::Any.new(eff_seuser)
      res.extra["serange"] = JSON::Any.new(eff_serange)
      res
    end

    # Splits a "seuser:role:setype:range" context string; "<<None>>"
    # maps to no user/type/range at all (the real module's nil fields).
    private def split_context(context : String) : {String?, String?, String?}
      return {nil, nil, nil} if context == "<<None>>"
      parts = context.split(':')
      return {nil, nil, nil} unless parts.size >= 3
      {parts[0], parts[2], parts[3]?}
    end

    private def capture_semanage(cmd : Array(String)) : {Int32, String, String}
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(cmd[0], cmd[1..], output: out_io, error: err_io)
      {status.success? ? 0 : 1, out_io.to_s, err_io.to_s}
    end

    private def run!(cmd : Array(String), what : String, check_mode : Bool) : Nil
      return if check_mode
      result = capture_semanage(cmd)
      unless result[0] == 0
        raise "#{what} failed: #{result[2].strip}"
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::SefcontextPlugin.new(config)
plugin.run
