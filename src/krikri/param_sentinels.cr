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

  # Prefix marking a set_fact param value as the JSON encoding of the
  # expression's NATIVELY-TYPED result, not substituted display text.
  # The executor's param wire is strings-only, so a whole-single-span
  # `{{ expr }}` set_fact value (the only shape real ansible-core 2.19
  # native-typing keeps unstringified) would otherwise arrive at the
  # set_fact plugin as bare text and get re-coerced by string shape -
  # which is pre-2.19 `ANSIBLE_JINJA2_NATIVE=off` literal_eval behavior,
  # not 2.19's "the expression's own type is the value's type" rule: a
  # Jinja string expression stays a str even when it looks like a number
  # (pluggero.openssh round 981024: "{{ '8.9' }}" became the float 8.9,
  # so `openssh_installed_version != openssh_pkg_mgr_version` compared
  # float-to-str and was always true, forcing a package reinstall every
  # run). The control character makes a false positive on a *literal*
  # (non-templated) set_fact value - which still takes the legacy
  # string-shape coercion below - effectively impossible.
  NATIVE_TYPED_PREFIX = "\u{E000}native:"
end
