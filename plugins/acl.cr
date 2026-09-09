#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/acl_command"

module Krikri
  # ansible.posix.acl - manages POSIX ACL entries on a file or
  # directory via getfacl(1)/setfacl(1). Ported from the real Python
  # module (ansible.posix plugins/modules/acl.py) - same parameter
  # handling (path/name alias, entry: shorthand vs entity/etype/
  # permissions, default: for directory default ACLs, recursive:,
  # follow:, recalculate_mask:, use_nfsv4_acls:), same command
  # construction, and same `setfacl --test` idempotency check (report
  # changed only when the would-be result line does not end in `*,*`).
  # See PluginHelpers::AclCommand for the split-out, spec-tested
  # command-construction half - every shape there is cross-checked
  # against real setfacl 2.3.2 output.
  class AclPlugin < BasePlugin
    ETYPES = %w[user group mask other]

    # run_acl's check_rc=True semantics: a nonzero exit fails the task
    # (getfacl/setfacl missing, filesystem without ACL support, invalid
    # entity, ...) - matches the real module's fail_json behavior.
    private def run_acl_checked(cmd : Array(String)) : Array(String)
      result = remote_exec(cmd.map { |word| Process.quote(word) }.join(' '))
      if result[:exit_code] != 0
        raise "failed to execute: #{cmd.join(' ')}\n#{result[:stderr]}"
      end
      PluginHelpers::AclCommand.filter_lines(result[:stdout])
    end

    # The real module's state: absent apply deliberately swallows
    # errors (run_acl with check_rc=False) - the changed check already
    # ran, and a removal racing a concurrent change is not worth
    # failing the task over.
    private def run_acl_untested(cmd : Array(String)) : Nil
      remote_exec(cmd.map { |word| Process.quote(word) }.join(' '))
      nil
    end

    # acl_changed: rerun the would-be command with `--test` inserted
    # right after the binary name (real module's exact insertion point,
    # so `-d`-bearing commands become `setfacl --test -d -m ...`).
    private def acl_changed?(command : Array(String), entry : String, use_nfsv4_acls : Bool) : Bool
      test_cmd = command.dup.insert(1, "--test")
      lines = run_acl_checked(test_cmd)
      PluginHelpers::AclCommand.changed?(lines, entry, use_nfsv4_acls)
    end

    def execute : PluginResult
      path = (@params["path"]? || @params["name"]?).try { |raw| expand_tilde(raw) }
      entry_param = @params["entry"]?
      entity = @params["entity"]? || ""
      etype = @params["etype"]?
      permissions = @params["permissions"]?
      state = @params["state"]? || "query"
      follow = true?(@params["follow"]?, default: true)
      default = true?(@params["default"]?)
      recursive = true?(@params["recursive"]? || @params["recurse"]?)
      recalculate_mask = @params["recalculate_mask"]? || "default"
      use_nfsv4_acls = true?(@params["use_nfsv4_acls"]?)
      check_mode = true?(@params["check_mode"]?)

      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: path") unless path

      # Real Ansible's argument_spec rejects an out-of-choices etype at
      # argument-validation time, before any state logic runs.
      if et = etype
        unless ETYPES.includes?(et)
          return PluginResult.new(changed: false, failed: true, msg: "value of etype must be one of: #{ETYPES.join(", ")}, got: #{et}")
        end
      end

      unless File.exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "Path not found or not accessible.")
      end

      if state == "query"
        if recursive
          return PluginResult.new(changed: false, failed: true, msg: "'recursive' MUST NOT be set when 'state=query'.")
        end
        if recalculate_mask == "mask" || recalculate_mask == "no_mask"
          return PluginResult.new(changed: false, failed: true, msg: "'recalculate_mask' MUST NOT be set to 'mask' or 'no_mask' when 'state=query'.")
        end
      end

      if entry_param.nil? || entry_param.empty?
        if state == "absent" && permissions && !permissions.empty? && !use_nfsv4_acls
          return PluginResult.new(changed: false, failed: true, msg: "'permissions' MUST NOT be set when 'state=absent'.")
        end
        if state == "absent" && entity.empty?
          return PluginResult.new(changed: false, failed: true, msg: "'entity' MUST be set when 'state=absent'.")
        end
        if (state == "present" || state == "absent") && etype.nil?
          return PluginResult.new(changed: false, failed: true, msg: "'etype' MUST be set when 'state=#{state}'.")
        end
      else
        # entry_param is a non-empty String in this branch (flow-narrowed
        # by the `nil? || empty?` condition above) - no not_nil! needed.
        if etype || !entity.empty? || permissions
          return PluginResult.new(changed: false, failed: true, msg: "'entry' MUST NOT be set when 'entity', 'etype' or 'permissions' are set.")
        end
        if state == "present" && ![2, 3].includes?(entry_param.count(':'))
          return PluginResult.new(changed: false, failed: true, msg: "'entry' MUST have 3 or 4 sections divided by ':' when 'state=present'.")
        end
        if state == "absent" && ![1, 2].includes?(entry_param.count(':'))
          return PluginResult.new(changed: false, failed: true, msg: "'entry' MUST have 2 or 3 sections divided by ':' when 'state=absent'.")
        end
        if state == "query"
          return PluginResult.new(changed: false, failed: true, msg: "'entry' MUST NOT be set when 'state=query'.")
        end

        d, etype, entity, permissions = PluginHelpers::AclCommand.split_entry(entry_param)
        default = d unless d.nil?
      end

      changed = false

      if state == "present"
        entry = PluginHelpers::AclCommand.build_entry(etype, entity, permissions, use_nfsv4_acls)
        command = PluginHelpers::AclCommand.build_command("set", path, follow, default, recursive, recalculate_mask, use_nfsv4_acls, entry)
        changed = acl_changed?(command, entry, use_nfsv4_acls)
        run_acl_checked(command) if changed && !check_mode
        msg = "#{entry} is present"
      elsif state == "absent"
        entry = if use_nfsv4_acls
                  PluginHelpers::AclCommand.build_entry(etype, entity, permissions, use_nfsv4_acls)
                else
                  PluginHelpers::AclCommand.build_entry(etype, entity, nil, use_nfsv4_acls)
                end
        command = PluginHelpers::AclCommand.build_command("rm", path, follow, default, recursive, recalculate_mask, use_nfsv4_acls, entry)
        changed = acl_changed?(command, entry, use_nfsv4_acls)
        run_acl_untested(command) if changed && !check_mode
        msg = "#{entry} is absent"
      else # query
        msg = "current acl"
      end

      acl = run_acl_checked(
        PluginHelpers::AclCommand.build_command("get", path, follow, default, recursive, recalculate_mask, use_nfsv4_acls)
      )

      PluginResult.new(changed: changed, failed: false, msg: msg, acl: acl)
    rescue ex : Exception
      PluginResult.new(changed: false, failed: true, msg: ex.message || "acl module error")
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::AclPlugin.new(config)
plugin.run
