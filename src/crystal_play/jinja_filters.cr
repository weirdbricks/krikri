require "crinja"

# Custom Jinja2 filters that real Ansible's Jinja2 provides but Crinja
# doesn't ship, registered into the global Crinja default library so they're
# available to every environment this process builds (the template module's
# own env and the shared CrinjaRenderer/{% %} env both start with
# register_defaults, so a filter added to Filter::Library.defaults here is
# visible in both).
#
# This file is required by template_action_plugin.cr (and therefore pulled
# into every binary that renders templates). Keep filters here scoped to
# what real playbooks actually use, verified against real ansible-playbook
# rather than assumed from Jinja2 docs. Positional arguments come through
# `arguments.varargs` (indexed by position), keyword args through
# `arguments.kwargs`.

module CrystalPlay
  module JinjaFilters
    # `comment` - wraps a value in a Jinja2 comment. Mirrors the plain
    # Jinja2 `comment` filter: a scalar becomes a `{# ... #}` block, a
    # multi-line value gets each line `#`-prefixed. The common role usage -
    # `{{ ansible_managed | comment }}` to emit an "Ansible managed" banner
    # - only needs the whole value wrapped as one comment.
    Crinja.filter(:comment) do
      value = target.to_s
      Crinja::Value.new("{# #{value.gsub("\n", " ")} #}")
    end

    # `bool` - coerce a value to a boolean the way Jinja2's bool filter does:
    # "true"/"yes"/"1"/"on" (case-insensitive) are true, everything else
    # (including nil and "false") is false. Used throughout os_hardening
    # templates for `{{ os_* | bool }}`.
    Crinja.filter(:bool) do
      Crinja::Value.new(
        case target.to_s.downcase
        when "true", "yes", "1", "on"
          true
        else
          false
        end
      )
    end

    # `ternary(true_value, false_value)` - Jinja2's conditional value
    # selection: returns the first argument when the target is truthy, the
    # second when falsy. os_hardening writes per-boolean configs this way:
    # `{{ os_auditd_write_logs | bool | ternary('yes', 'no') }}`.
    Crinja.filter(:ternary) do
      true_arg = arguments.varargs[0]?
      false_arg = arguments.varargs[1]?
      picked = if target.truthy?
                 true_arg || Crinja::Value.new("")
               else
                 false_arg || Crinja::Value.new("")
               end
      Crinja::Value.new(picked)
    end

    # `difference(iterable)` - set difference: the elements of the target
    # sequence not present in the argument sequence. os_hardening's
    # modprobe task uses it to subtract mounted fs types from a candidate
    # list: `os_unused_filesystems | difference(ansible_facts.mounts |
    # map(attribute='fstype') | list)`.
    Crinja.filter(:difference) do
      arg = arguments.varargs[0]?
      target_vals = target.sequence? ? target.to_a : [] of Crinja::Value
      arg_set = Array(Crinja::Value).new
      a = arg
      arg_set = a.to_a if a && a.sequence?
      Crinja::Value.new(target_vals.reject { |item| arg_set.includes?(item) })
    end
  end
end
