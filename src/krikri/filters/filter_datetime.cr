require "json"
require "time"

module Krikri
  module VariableSubstitutor
    # Datetime filter support (to_datetime's tagged-epoch representation and
    # its parse helper)
    class FilterEngine
      DATETIME_TAG  = "__crystal_datetime__"
      TIMEDELTA_TAG = "__crystal_timedelta__"

      private def parse_to_datetime(value : JSON::Any, format : String) : JSON::Any
        time = Time.parse(as_string(value), format, Time::Location::UTC) rescue nil
        return JSON::Any.new(nil) unless time
        JSON::Any.new({DATETIME_TAG => JSON::Any.new(time.to_unix.to_i64)})
      end
    end
  end
end
