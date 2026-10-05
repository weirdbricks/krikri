require "json"

module Krikri
  module PluginHelpers
    # MysqlInfoVersion - parses a `SELECT VERSION()` string into the
    # `version:` fact shape real community.mysql.mysql_info reports
    # (its own __get_global_variables): split on '.', take release/suffix
    # from the THIRD component only, and leave `full` unmodified. Kept
    # out of plugins/mysql_info.cr itself so it can be unit-spec'd
    # without pulling in the plugin binary's STDIN entry point.
    module MysqlInfoVersion
      def self.parse(full : String) : Hash(String, JSON::Any)
        parts = full.split('.')
        third = parts.size > 2 ? parts[2] : ""
        release = third.partition('-')[0]
        suffix = third.split('-', 2).size > 1 ? third.split('-', 2)[1] : ""

        {
          "major"   => JSON::Any.new(parts[0]?.try(&.to_i64?) || 0_i64),
          "minor"   => JSON::Any.new(parts[1]?.try(&.to_i64?) || 0_i64),
          "release" => JSON::Any.new(release.to_i64? || 0_i64),
          # Ansible's dict(...) names suffix before full - the registered
          # key order of `version` follows its dict, not this Hash's.
          "suffix" => JSON::Any.new(suffix),
          "full"   => JSON::Any.new(full),
        }
      end
    end
  end
end
