# Shared between the executor's param-finalization path (variable_
# substitutor.cr) and the plugin-side BasePlugin param parsing, which
# compile into DIFFERENT binaries (krikri-playbook vs each bin/plugins/*
# binary) and share no other file that both already require - so the
# sentinel constant lives here, in the one file both sides can require
# without dragging the whole substitutor (Crinja and all) into every
# plugin binary or base_plugin into the main executable.
module Krikri
  # The null/None counterpart to OMIT_SENTINEL (variable_substitutor.cr).
  # The param wire between the executor and a plugin binary is
  # strings-only, so a module call whose param natively resolved to
  # Python None (`enablerepo: "{{ item.enablerepo | default('') }}"` with
  # a null item field - round 900905 officel.httpd) would collapse to the
  # same "" as a real empty string, which real Ansible's argument specs
  # treat completely differently (an explicit None fails every `type:
  # list` param; an empty string coerces to an empty list just fine -
  # live-verified against ansible-core 2.19.11). The executor marks such
  # params with this sentinel, BasePlugin demotes it back to "" (plus a
  # null bookkeeping entry) so every plugin that never asks about it
  # stays behavior-identical, and only plugins that mirror a real
  # module's argspec consult BasePlugin#explicit_null_param?.
  NONE_SENTINEL = "__crystal_ansible_none__"
end
