#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # set_fact plugin - sets arbitrary variables for subsequent tasks on the
  # same host (ansible.builtin.set_fact). Never touches the filesystem or
  # network and never reports changed, so it's safe under --check.
  #
  # Unlike most plugins here, set_fact needs no action-plugin machinery: it
  # simply echoes its own (already-substituted) params back as
  # `ansible_facts`, the same generic result field the "facts" plugin
  # already returns from gather_facts - TaskExecutor merges any task
  # result's `ansible_facts` into that host's fact store, so set_fact just
  # needs to be a plain module that returns one.
  class SetFactPlugin < BasePlugin
    # set_fact's own control parameter, not a fact to set. `cacheable:`
    # (persisting into a fact cache plugin) has no cache backend to persist
    # into here, so it's accepted and ignored rather than turned into a
    # literal `cacheable` fact.
    CONTROL_PARAMS = {"cacheable"}

    def execute : PluginResult
      facts = Hash(String, JSON::Any).new

      @params.each do |key, value|
        next if CONTROL_PARAMS.includes?(key)
        facts[key] = coerce(value)
      end

      PluginResult.new(
        changed: false,
        failed: false,
        msg: "",
        ansible_facts: JSON::Any.new(facts)
      )
    end

    # Best-effort scalar type coercion. Params arrive here as plain
    # substituted strings (TaskExecutor substitutes every task param to a
    # String before handing it to a plugin), so a fact set from a bool/int/
    # float-looking template result needs to be coerced back to that type
    # rather than staying a string - matching how a subsequent when:/{{ }}
    # comparison would expect it to behave.
    private def coerce(value : String) : JSON::Any
      case value
      when "true", "True", "yes"
        JSON::Any.new(true)
      when "false", "False", "no"
        JSON::Any.new(false)
      else
        if leading_zero_number?(value)
          # Real bug found live-verifying the Crinja templating convergence
          # work against dev-sec os_hardening: `.to_i64?` happily
          # parses "0755" as decimal 755 - Crystal's decimal integer
          # parsing simply ignores leading zeros, the same way `"0755".
          # to_i` does in most languages. os_hardening's own dynamic
          # `set_fact: "{{ item.key }}": "{{ item.value }}"` (see the
          # comment on the JSON branch below) round-trips EVERY
          # os_mnt_*_dir_mode/os_*_perms value through this coercion,
          # silently turning the octal-style mode STRING "0755" into the
          # int 755 - which downstream (`file: mode: "{{ ... }}"`, fed
          # straight to a chmod syscall expecting octal bits) applied as
          # mode 01363 instead of 0755 (755 read as octal digits, not
          # decimal), corrupting real directory permissions on
          # `/dev`/`/run`/`/var`/`/home`/`/tmp`/`/dev/shm`/`/var/tmp` on
          # a live host. A leading zero followed by more digits is never
          # a genuine decimal integer literal (Python 3 itself rejects
          # `0755` as invalid int syntax) - always either a deliberate
          # octal-style string (this codebase's own file-mode convention)
          # or otherwise never meant to lose that leading zero, so it's
          # excluded from int coercion entirely and falls through to the
          # plain-string case below.
          JSON::Any.new(value)
        elsif value.matches?(/\A[0-7]{3,4}\z/)
          # Same class of bug, one zero shorter: an octal-MODE-shaped
          # string with no leading zero ("1777" - os_hardening's own
          # /dev/shm, /tmp and /var/tmp entries are exactly this shape)
          # decimal-coerced into the int 1777. Real Ansible's native
          # typing keeps a string-sourced fact a string, and the string
          # is what downstream mode:/consumers need - a fed-back int
          # instead re-triggers the executor's int-mode reformatting
          # (`'%04o'`, see substitute_task_params's key == "mode"
          # comment), turning "1777" into "3361" and corrupting real
          # directory permissions again. The executor's reformat can
          # afford to be unconditional (and must be - geerlingguy.redis's
          # `mode: "{{ redis_conf_mode }}"` with 0640's decimal 416 was
          # misapplied as octal 416, never converging against
          # redis-server's own postinst chmod 640) precisely because this
          # coercion no longer manufactures fake ints out of octal-shaped
          # strings. Numeric comparisons are unaffected either way -
          # compare_values parses both sides numerically.
          JSON::Any.new(value)
        elsif int_value = value.to_i64?
          JSON::Any.new(int_value)
        elsif float_value = value.to_f64?
          JSON::Any.new(float_value)
        elsif (value.starts_with?('{') || value.starts_with?('[')) && (parsed = try_parse_json(value))
          # A dict/list-valued fact (e.g. dynamic `set_fact: "{{
          # item.key }}": "{{ item.value }}"` over a dict item, as
          # dev-sec os_hardening's os_shadow_perms/os_passwd_perms are
          # built) arrives here as the JSON text VariableLookup#format_value
          # serialized it to - parse it back to a real Hash/Array so
          # later dotted access (`os_shadow_perms.owner`) works, instead
          # of leaving it a flat string that renders "undefined".
          parsed
        else
          JSON::Any.new(value)
        end
      end
    end

    private def try_parse_json(value : String) : JSON::Any?
      # Valid JSON only - never a Python-repr repair pass. Native
      # containers (a whole-value `{{ some_list }}` set_fact) arrive as
      # the double-quoted JSON VariableLookup#format_value serialized
      # them to; a value that merely LOOKS like a container (a
      # `{% if %}...{% else %}['dummy']{% endif %}` block's rendered
      # output, or a plain quoted "['a']" literal) is a plain STRING in
      # real ansible-core - native typing requires the template's whole
      # AST to be one output node wrapping one expression, so block-tag
      # output is never re-parsed. Found live vs real ansible-playbook
      # via HanXHX.debian_bootstrap: the repr-looking string became a
      # real ARRAY here, so `loop: "{{ dbs_repo_old }}"` silently
      # iterated where real Ansible hard-fails with "The `loop` value
      # must resolve to a 'list', not 'str'."
      JSON.parse(value)
    rescue JSON::ParseException
      nil
    end

    # "0", "0.5" - real numbers, fine to coerce. "0755", "0007" - a
    # leading zero followed by MORE digits, never a genuine decimal
    # integer/float literal (see the call site's own comment).
    private def leading_zero_number?(value : String) : Bool
      value.size > 1 && value[0] == '0' && value[1].ascii_number?
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::SetFactPlugin.new(config)
plugin.run
