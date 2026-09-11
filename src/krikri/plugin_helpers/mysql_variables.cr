require "json"

module Krikri
  module PluginHelpers
    # MysqlVariables - pure logic for the mysql_variables plugin: the
    # real module's typedvalue conversion, its ON/OFF boolean
    # normalization, the variable-name validation, and SET statement
    # construction (backtick-quoted identifier like the real module's
    # mysql_quote_identifier(..., 'vars')). Split out so this logic is
    # unit-spec-able (execution needs a real MySQL/MariaDB server).
    module MysqlVariables
      # The real module's validation: ^[0-9A-Za-z_.]+$ on the variable
      # name, failing with "invalid variable name \"X\"".
      def self.valid_name?(variable : String) : Bool
        /^[0-9A-Za-z_.]+$/.matches?(variable)
      end

      # Convert value to number whenever possible, keep strings as-is
      # (the real module's typedvalue).
      def self.typed_value(value : String) : String | Int64 | Float64
        value.to_i64? || value.to_f64? || value
      end

      # Converts 0/1/on/off wanted values to ON/OFF when the server's
      # current representation is ON/OFF (the real module's
      # convert_bool_setting_value_wanted).
      def self.convert_bool(value : String | Int64 | Float64) : String | Int64 | Float64
        case value.to_s.downcase
        when "on", "1" then "ON"
        when "off", "0" then "OFF"
        else value
        end
      end

      # Numeric-looking strings compare equal to the server's numeric
      # strings ("1" == 1 == 1.0) without issuing a SET.
      def self.values_equal?(wanted : String | Int64 | Float64, actual : String | Int64 | Float64) : Bool
        return wanted == actual if wanted.is_a?(String) && actual.is_a?(String) &&
                                   !numeric_string?(wanted) && !numeric_string?(actual)
        normalize_number(wanted) == normalize_number(actual)
      end

      private def self.numeric_string?(value : String) : Bool
        value.to_f64?.try { |_| true } || false
      end

      private def self.normalize_number(value : String | Int64 | Float64) : Float64
        value.to_s.to_f64
      end

      # SET statement construction: SET GLOBAL/PERSIST/PERSIST_ONLY
      # `variable` = value. Booleans sent as ON/OFF strings, numbers as
      # bare literals, everything else as a quoted literal.
      def self.set_statement(variable : String, value : String | Int64 | Float64, mode : String) : String
        keyword = mode == "persist" ? "PERSIST" : mode == "persist_only" ? "PERSIST_ONLY" : "GLOBAL"
        literal = value.is_a?(String) && !(value == "ON" || value == "OFF") ? "'#{value.gsub("'", "''")}'" : value.to_s
        "SET #{keyword} `#{variable}` = #{literal}"
      end
    end
  end
end
