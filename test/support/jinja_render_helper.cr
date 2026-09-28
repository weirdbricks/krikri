require "json"
require "krikri-jinja/krikri_jinja"
require "../../src/krikri/krikri_jinja_filters"

# Renders *tpl* on the shared krikri-jinja engine with krikri's Ansible
# registrations - the engine a real `.j2` template renders with - from
# plain Crystal or JSON::Any variables.
def krikri_jinja_render(tpl : String, vars = nil) : String
  variables = {} of String => KrikriJinja::AnyValue
  vars.try &.each { |key, value| variables[key.to_s] = KrikriJinja.wrap_value(value) }
  KrikriJinja.render(tpl, variables)
end
