require "json"
require "./param_sentinels"

# ansible-core 2.21 flipped the INJECT_INVOCATION default to false: module
# results carry no `invocation` key at all unless it is enabled
# (AnsibleModule._return_formatted pops the key when the action layer did
# not pass `_ansible_inject_invocation`, and the action layer resolves it
# from the config value each task run - live-verified vs 2.21.6 with the
# #909 repro playbook, where `r.results[0].invocation` is undefined under
# real 2.21.6 but present under 2.19.11).
#
# Ansible's own resolution order for the setting is: the
# `ansible_inject_invocation` variable (highest, resolved per task with
# task_vars) > the ANSIBLE_INJECT_INVOCATION environment variable > the
# ansible.cfg [defaults] inject_invocation ini key > false. krikri has no
# ansible.cfg INI parsing anywhere (deliberate, env/CLI only), so the ini
# tier is unsupported here the same way every other config-backed setting
# is.
module Krikri
  module InvocationInjection
    extend self

    def enabled?(vars_context : Hash(String, JSON::Any)? = nil) : Bool
      if vars_context && (value = vars_context["ansible_inject_invocation"]?)
        if text = value.as_s?
          return Krikri.lenient_boolean_true?(text)
        end
        return value.as_bool? == true
      end
      if env = ENV["ANSIBLE_INJECT_INVOCATION"]?
        return Krikri.lenient_boolean_true?(env)
      end
      false
    end

    # The inverse side of the same config: every result path that would
    # otherwise carry `invocation` (a native plugin's own echo - copy,
    # getent - or a real Python module's kwargs) must shed it when the
    # setting is off, exactly as AnsibleModule._return_formatted pops it.
    def strip(result : JSON::Any) : JSON::Any
      hash = result.as_h? || return result
      return result unless hash.has_key?("invocation")
      stripped = hash.dup
      stripped.delete("invocation")
      JSON::Any.new(stripped)
    end
  end
end
