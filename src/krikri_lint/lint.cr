require "./version"
require "./severity"
require "./file_type"
require "./violation"
require "./positioned_yaml"
require "./file_discovery"
require "./rule"
require "./rule_registry"
require "./profiles"
require "./task"
require "./rules/*"
require "./runner"

module Krikri
  module Lint
    VERSION = KRIKRI_LINT_VERSION
  end
end
