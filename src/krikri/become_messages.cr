# The become-failure message constants shared by PluginManager (which
# books these failures) and ResultDisplay (which recognizes them when
# rendering the [ERROR] block). They live in their own leaf file so
# result_display.cr does not have to require plugin_manager.cr - that
# require closed a require cycle
# (base_action_plugin -> inventory_parser -> inventory_plugins ->
# conditional_evaluator -> filter_engine -> krikri_jinja_filters ->
# result_display -> plugin_manager -> action_plugin_manager ->
# template_action_plugin -> base_action_plugin) in which
# template_action_plugin's `class TemplateActionPlugin < ActionPlugin`
# was reached before base_action_plugin.cr's body had defined
# ActionPlugin, so any compile that pulled base_action_plugin in first
# died with "undefined constant ActionPlugin" (a single-file spec
# compile, or a suite shard whose first file required it).
module Krikri
  module BecomeMessages
    PREMATURE_END = "Premature end of stream waiting for become success."

    METHOD_EMPTY = "A non-empty plugin name is required."

    CHOWN_FAILURE = "Failed to change ownership of the temporary files Ansible (via chmod nor setfacl) needs to create despite connecting as a privileged user. Unprivileged become user would be unable to read the file."
  end
end
