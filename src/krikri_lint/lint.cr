require "./version"
require "./severity"
require "./file_type"
require "./violation"
require "./positioned_yaml"
require "./file_discovery"
require "./rule"
require "./rule_registry"

# The runner's syntax-check gate reuses the engine's controller-side
# module resolution (CollectionIndex, whose library/action-plugin
# lookups live in PythonFilterRunner) so "would this file fail
# ansible's load?" gets the same answer krikri-playbook gives it.
require "../krikri/collection_index"
require "../krikri/python_filter_runner"

require "./config"
require "./noqa"
require "./json_schema"
require "./arg_specs"
require "./profiles"
require "./task"
require "./fixer"
require "./rules/*"
require "./runner"
require "./console"
require "./report"
require "./imports"

module Krikri
  module Lint
    VERSION = KRIKRI_LINT_VERSION
  end
end
