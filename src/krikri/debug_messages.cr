module Krikri
  # debug:'s `var:` option is evaluated as a Jinja EXPRESSION by its action
  # plugin on the controller, and ansible-core wraps every failure of that
  # evaluation in this framing (live-verified vs 2.21.6: a missing lookup, a
  # failing filter, a `{% do %}` tag in the value, a division by zero). The
  # framing is the fatal msg's and the [ERROR] chain's cause segment, so the
  # plugin, the executor's result shaping and the display all match on it.
  #
  # A leaf file so result_display can require it: its own require of
  # base_action_plugin closed a cycle (base_action_plugin ->
  # inventory_parser -> python_vars_runner -> python_filter_runner ->
  # result_display), leaving ActionPlugin undefined mid-compile.
  DEBUG_VAR_EXPRESSION_PREFIX = "Error while resolving `var` expression: "
end
