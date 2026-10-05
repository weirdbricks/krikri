#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/group_state"

module Krikri
  # Group plugin - manages a system group via getent/groupadd/groupmod/groupdel
  # Compatible with (a subset of) Ansible's ansible.builtin.group module
  #
  # Parameters:
  #   name (required)
  #   state (optional): present (default) or absent
  #   gid (optional)
  #   system (optional, default no): pass -r to groupadd for a system group
  #     (passed to lgroupadd on the local path too - Ansible emits it
  #     there unconditionally and libuser's lgroupadd accepts it)
  #   force (optional, default no): groupdel's -f flag - delete the group
  #     even when it is some user's primary group. DELETE-only:
  #     ansible.builtin.group's Linux path never passes anything to
  #     groupadd/groupmod for force (its documented meaning is "delete a
  #     group even if it is the primary group of a user", live-verified:
  #     `groupdel -f root`). Mutually exclusive with local: - Ansible
  #     fails before anything runs (live-verified text below); libuser's
  #     lgroupdel has no -f and the module's local branch never emits one.
  #   non_unique (optional, default no): allow a duplicate gid -
  #     groupadd/groupmod `-o`, only ever emitted together with a gid that
  #     is being set (create) or changed (modify), matching Ansible's
  #     own nesting of -o inside its gid branches. Ansible REQUIRES
  #     gid: whenever non_unique: is given (required_if - live-verified
  #     failure text replicated below).
  #   gid_min/gid_max (optional): groupadd's -K GID_MIN=.../-K GID_MAX=...
  #     - constrains the auto-assigned gid range at CREATION only (Ansible's group_mod branch never emits them, live-verified).
  #     Mutually exclusive with local: (Ansible fails before anything
  #     runs - live-verified texts below).
  #   local (optional, default no): operate on the local group files only,
  #     bypassing NSS - existence is checked by reading /etc/group directly
  #     (never `getent`, which would find a directory/SSSD/LDAP group; the
  #     scan is Ansible's own reversed-lines one, so the LAST matching
  #     "name:" line wins), and every mutation routes through libuser's
  #     tools (lgroupadd/lgroupmod/lgroupdel) instead of shadow-utils.
  #     Before every lgroupadd/lgroupmod carrying a gid, Ansible
  #     pre-checks the NSS-wide group list (grp.getgrall) and fails with
  #     "GID '<gid>' already exists with group '<owner>'" when a DIFFERENT
  #     group already owns that gid - even with non_unique: (live-verified);
  #     gid 0 skips that check (the Ansible module's Python `if self.gid:`
  #     truthiness, live-verified). Mirrors the user module's
  #     already-implemented local: pattern.
  #
  # Ansible returns name/state always, and gid/system whenever the
  # group exists after the task - attached to the result here the same way.
  #
  # Registered-result key order (live-verified vs ansible-core 2.19.11 on
  # Ubuntu 22.04, round 992000 + local container replay): group.py builds
  # result = {name, state} first, then changed (after the branch), then
  # system/gid from the post-task group_info - so every exists-after path
  # registers [name, state, changed, system, gid, failed], while the
  # check-mode create of a missing group exits early with just
  # exit_json(changed=True) -> [changed, failed], and the absent path
  # never carries system/gid at all. Command failures fail_json(name=,
  # msg=) and register [name, failed, msg, changed, exception] - the name
  # kwarg LEADS, before failed/msg (Ansible's fail_json kwargs-first rule).
  class GroupPlugin < BasePlugin
    # group_exists-after-task result: name/state, then changed, then the
    # group_info fields (system first, gid last).
    GROUP_EXISTS_ORDER = ["name", "state", "changed", "system", "gid"]
    # state=absent result: name/state/changed only - no system/gid.
    GROUP_ABSENT_ORDER = ["name", "state", "changed"]
    # check-mode early exit_json(changed=True) - nothing else.
    GROUP_CHECK_ONLY_ORDER = ["changed"]
    # fail_json(name=group.name, msg=err): the kwargs lead, then the
    # fail_json backfill (failed, msg), then changed, then exception.
    GROUP_FAIL_ORDER = ["name", "failed", "msg", "changed", "exception"]

    # ansible.builtin.group's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.group). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[force local non_unique system]
    end

    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name
      validate_bool_params!

      # Ansible's argument-validation order (live-verified): the
      # AnsibleModule ctor's required_if check first, then main()'s
      # force+local mutual-exclusion, then Group.__init__'s gid_min/gid_max
      # + local refusals - all before any state read.
      if failure = param_validation_failure
        return failure
      end

      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # Ansible's own group_exists guard for local: os.path.exists on
      # /etc/group first, exact message (it fails BEFORE any state read).
      if local?
        probe = remote_exec("test -f /etc/group")
        unless probe[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "'local: true' specified but unable to find local group file /etc/group to parse.")
        end
      end

      current = lookup(name)

      if state == "absent"
        ensure_absent(name, current, check_mode)
      else
        ensure_present(name, current, check_mode)
      end
    end

    # `local: true` bypasses NSS for the existence check: Ansible's
    # own group_exists() reads /etc/group directly (its own comment: the
    # grp module "does not distinguish between local and directory
    # accounts"), because getent would happily report a directory/SSSD/
    # LDAP group that the libuser tools cannot touch. Fails with
    # Ansible's own message when the file can't be read at all.
    private def lookup(name : String) : PluginHelpers::GroupState::Group?
      if local?
        result = remote_exec("cat /etc/group")
        return nil unless result[:exit_code] == 0
        return PluginHelpers::GroupState.local_parse(result[:stdout], name)
      end

      result = remote_exec("getent group #{shell_single_quote(name)}")
      return nil unless result[:exit_code] == 0
      PluginHelpers::GroupState.parse(result[:stdout])
    end

    private def local? : Bool
      true?(@params["local"]?)
    end

    # Ansible's own argument validations, each with its exact
    # live-verified message:
    # - required_if: [['non_unique', True, ['gid']]] (AnsibleModule ctor)
    # - force+local mutual exclusion (main(), before Group.__init__)
    # - gid_min/gid_max + local refusals (Group.__init__)
    private def param_validation_failure : PluginResult?
      if true?(@params["non_unique"]?) && !@params["gid"]?.presence
        return PluginResult.new(changed: false, failed: true,
          msg: "non_unique is True but all of the following are missing: gid")
      end

      if true?(@params["force"]?) && local?
        return PluginResult.new(changed: false, failed: true,
          msg: "force is not a valid option for local, force=True and local=True are mutually exclusive")
      end

      if local?
        if @params["gid_min"]?.presence
          return PluginResult.new(changed: false, failed: true,
            msg: "'gid_min' can not be used with 'local'")
        end
        if @params["gid_max"]?.presence
          return PluginResult.new(changed: false, failed: true,
            msg: "'gid_max' can not be used with 'local'")
        end
      end

      nil
    end

    # Ansible's own _local_check_gid_exists, run before every
    # lgroupadd/lgroupmod carrying a gid: scan the NSS-wide group list
    # (getent group, full db) for a DIFFERENT group owning the same gid.
    private def local_gid_conflict(name : String, gid : String?) : PluginResult?
      g = gid.presence
      return nil unless g && local?

      result = remote_exec("getent group")
      return nil unless result[:exit_code] == 0
      if owner = PluginHelpers::GroupState.local_gid_conflict(result[:stdout], name, g)
        PluginResult.new(changed: false, failed: true,
          msg: "GID '#{g}' already exists with group '#{owner}'")
      end
    end

    private def ensure_absent(name : String, current : PluginHelpers::GroupState::Group?, check_mode : Bool) : PluginResult
      unless current
        # Real group.py echoes name/state with changed: false even for a
        # group that doesn't exist (its main() sets both before the state
        # branches run); no msg on success.
        absent = PluginResult.new(changed: false, failed: false, key_order: GROUP_ABSENT_ORDER)
        attach_identity(absent, name, "absent")
        return absent
      end

      # Ansible exits with bare exit_json(changed=True) in check mode - no
      # name/state echo at all (registered shape: [changed, failed]).
      return PluginResult.new(changed: true, failed: false, key_order: GROUP_CHECK_ONLY_ORDER) if check_mode

      # force is delete-only (see class comment) - groupdel's -f, never
      # anything on the add/mod path; force+local already failed above.
      args = ["-f"] if true?(@params["force"]?)
      args ||= [] of String
      args << shell_single_quote(name)
      result = remote_exec("#{local? ? "lgroupdel" : "groupdel"} #{args.join(" ")}")
      return command_failure(name, "remove group", result) unless result[:exit_code] == 0

      removed = PluginResult.new(changed: true, failed: false, key_order: GROUP_ABSENT_ORDER)
      attach_identity(removed, name, "absent")
      removed
    end

    private def ensure_present(name : String, current : PluginHelpers::GroupState::Group?, check_mode : Bool) : PluginResult
      gid = @params["gid"]?
      system = true?(@params["system"]?)
      non_unique = true?(@params["non_unique"]?)

      unless current
        # Ansible exits with bare exit_json(changed=True) in check mode - the
        # create branch early-outs before anything else runs.
        return PluginResult.new(changed: true, failed: false, key_order: GROUP_CHECK_ONLY_ORDER) if check_mode

        if conflict = local_gid_conflict(name, gid)
          return conflict
        end

        args = PluginHelpers::GroupState.groupadd_args(name, gid, system, non_unique,
          @params["gid_min"]?, @params["gid_max"]?, local?)
        result = remote_exec("#{local? ? "lgroupadd" : "groupadd"} #{args.join(" ")}")
        return command_failure(name, "create group", result) unless result[:exit_code] == 0

        return attach_facts(PluginResult.new(changed: true, failed: false, key_order: GROUP_EXISTS_ORDER),
          name, state: "present", lookup_facts: true)
      end

      flags = PluginHelpers::GroupState.groupmod_flags(current, gid, non_unique)
      if flags.empty?
        return attach_facts(PluginResult.new(changed: false, failed: false, key_order: GROUP_EXISTS_ORDER),
          name, state: "present", facts: current)
      end

      # Check mode with an actual change: Ansible's group_mod returns rc=0
      # without running groupmod - the full exists-after shape with the
      # requested change reported.
      return attach_facts(PluginResult.new(changed: true, failed: false, key_order: GROUP_EXISTS_ORDER),
        name, state: "present", facts: current) if check_mode

      if conflict = local_gid_conflict(name, gid)
        return conflict
      end

      result = remote_exec("#{local? ? "lgroupmod" : "groupmod"} #{flags.join(" ")} #{shell_single_quote(name)}")
      return command_failure(name, "modify group", result) unless result[:exit_code] == 0

      attach_facts(PluginResult.new(changed: true, failed: false, key_order: GROUP_EXISTS_ORDER),
        name, state: "present", lookup_facts: true)
    end

    private def attach_identity(result : PluginResult, name : String, state : String) : Nil
      result.extra["name"] = JSON.parse(name.to_json)
      result.extra["state"] = JSON.parse(state.to_json)
    end

    # Ansible's result shape: name/state always, gid/system whenever
    # the group exists after the task (gid as a real int, system as the
    # requested param, not a derived fact). A create/modify may have
    # changed exactly the gid a later registered-var consumer reads, so
    # the post-task state is re-read rather than reusing the pre-task one.
    private def attach_facts(result : PluginResult, name : String, state : String, facts : PluginHelpers::GroupState::Group? = nil, lookup_facts : Bool = false) : PluginResult
      resolved = lookup_facts ? lookup(name) : facts
      result.extra["name"] = JSON.parse(name.to_json)
      result.extra["state"] = JSON.parse(state.to_json)
      if facts_group = resolved
        gid = facts_group.gid.to_i64?
        result.extra["gid"] = JSON.parse((gid || 0).to_s)
        result.extra["system"] = JSON.parse(true?(@params["system"]?).to_s)
      end
      result
    end

    # Ansible's group create/modify/delete failures are all
    # `fail_json(name=group.name, msg=err)` - msg is the raw stderr
    # (trailing newline included, live-verified vs 2.19.11: "groupadd:
    # Invalid configuration: GID_MIN (1000), GID_MAX (86)\n"), plus the
    # name echo. No "Failed to <action>: " prefix, no stdout fallback:
    # Ansible passes err (stderr) only, even when it is empty.
    private def command_failure(name : String, action : String, result : NamedTuple(exit_code: Int32, stdout: String, stderr: String)) : PluginResult
      failure = PluginResult.new(changed: false, failed: true, msg: result[:stderr], key_order: GROUP_FAIL_ORDER)
      failure.extra["name"] = JSON.parse(name.to_json)
      failure
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::GroupPlugin.new(config)
plugin.run
