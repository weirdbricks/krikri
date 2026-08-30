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
        msg: "ok",
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
          # Real bug found live-verifying CRINJA.md step 5's templating
          # convergence against dev-sec os_hardening: `.to_i64?` happily
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
      JSON.parse(value)
    rescue JSON::ParseException
      # A Python-repr list/dict (single-quoted, from a Jinja `{% if %}
      # ...{{ [list] }}...{% endif %}` template rendering as Python's
      # str() form) isn't valid JSON - same fallback as apt.cr/
      # package.cr/dnf.cr/unarchive.cr's own copies of this logic.
      # Proactive fix - not yet caught live for set_fact: specifically,
      # but the same bug class already found independently in four
      # other plugins. Narrow: only attempted on a value that already
      # starts with `{`/`[` (the caller's own gate), so this can't
      # misfire on an ordinary string value.
      JSON.parse(value.gsub('\'', '"')) rescue nil
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
