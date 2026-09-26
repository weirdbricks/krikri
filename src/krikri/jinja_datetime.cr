require "json"
require "krikri-jinja/krikri_jinja"

module Krikri
  # Python's naive `datetime.datetime` and `datetime.timedelta` as
  # krikri-jinja host objects, for `to_datetime`/`now()` and the arithmetic
  # Ansible templates do on them. Output formats follow CPython, pinned
  # against real ansible-core 2.19 (str, repr, ISO JSON, timedelta
  # normalization with negative days).
  module JinjaDateTime
    alias AnyValue = KrikriJinja::AnyValue

    MICROS_PER_SECOND = 1_000_000_i64
    MICROS_PER_DAY    = 86_400_i64 * MICROS_PER_SECOND

    # A naive datetime: wall-clock fields with no zone, held as a UTC Time.
    class DateTime < KrikriJinja::HostObject
      getter time : Time

      def initialize(@time : Time)
      end

      def to_s(io : IO) : Nil
        io << @time.to_s("%Y-%m-%d %H:%M:%S")
        io << '.' << microsecond.to_s.rjust(6, '0') if microsecond != 0
      end

      def repr : String
        fields = [@time.year, @time.month, @time.day, @time.hour, @time.minute]
        fields << @time.second if @time.second != 0 || microsecond != 0
        fields << microsecond if microsecond != 0
        "datetime.datetime(#{fields.join(", ")})"
      end

      def microsecond : Int32
        @time.nanosecond // 1000
      end

      def isoformat : String
        text = @time.to_s("%Y-%m-%dT%H:%M:%S")
        microsecond != 0 ? "#{text}.#{microsecond.to_s.rjust(6, '0')}" : text
      end

      def to_json_any : JSON::Any
        JSON::Any.new(isoformat)
      end

      def get_attr(name : String) : AnyValue?
        case name
        when "year"        then AnyValue.new(@time.year.to_i64)
        when "month"       then AnyValue.new(@time.month.to_i64)
        when "day"         then AnyValue.new(@time.day.to_i64)
        when "hour"        then AnyValue.new(@time.hour.to_i64)
        when "minute"      then AnyValue.new(@time.minute.to_i64)
        when "second"      then AnyValue.new(@time.second.to_i64)
        when "microsecond" then AnyValue.new(microsecond.to_i64)
        when "strftime"
          method(name) { |args| AnyValue.new(@time.to_s(JinjaDateTime.text(args[0]? || AnyValue.new("")))) }
        when "isoformat" then method(name) { |_args| AnyValue.new(isoformat) }
        when "weekday"   then method(name) { |_args| AnyValue.new((@time.day_of_week.value - 1).to_i64) }
        when "isoweekday" then method(name) { |_args| AnyValue.new(@time.day_of_week.value.to_i64) }
        when "timestamp"
          # A naive datetime's timestamp() reads it in the controller's
          # local zone, as CPython does.
          method(name) do |_args|
            local = Time.local(@time.year, @time.month, @time.day, @time.hour, @time.minute, @time.second,
              nanosecond: @time.nanosecond, location: Time::Location.local)
            AnyValue.new(local.to_unix_f)
          end
        end
      end

      def binary_op(op : String, other : AnyValue, reflected : Bool) : AnyValue?
        case {op, other.raw}
        when {"-", DateTime}
          return nil if reflected
          AnyValue.new(TimeDelta.new(JinjaDateTime.micros_between(other.raw.as(DateTime).time, @time)))
        when {"-", TimeDelta}
          return nil if reflected
          AnyValue.new(DateTime.new(@time - Time::Span.new(nanoseconds: other.raw.as(TimeDelta).micros * 1000)))
        when {"+", TimeDelta}
          AnyValue.new(DateTime.new(@time + Time::Span.new(nanoseconds: other.raw.as(TimeDelta).micros * 1000)))
        end
      end

      def compare(other : AnyValue) : Int32?
        other.raw.as?(DateTime).try { |date| @time <=> date.time }
      end

      private def method(name : String, &block : Array(AnyValue) -> AnyValue) : AnyValue
        AnyValue.new(KrikriJinja::SimpleCallable.new(name) { |args, _kwargs, _ctx| block.call(args) })
      end
    end

    # A duration in microseconds, normalized like CPython's timedelta:
    # `days` carries the sign, `seconds` and `microseconds` never do.
    class TimeDelta < KrikriJinja::HostObject
      getter micros : Int64

      def initialize(@micros : Int64)
      end

      def days : Int64
        @micros // MICROS_PER_DAY
      end

      def seconds : Int64
        (@micros - days * MICROS_PER_DAY) // MICROS_PER_SECOND
      end

      def microseconds : Int64
        @micros - days * MICROS_PER_DAY - seconds * MICROS_PER_SECOND
      end

      def to_s(io : IO) : Nil
        if days != 0
          io << days << (days.abs == 1 ? " day, " : " days, ")
        end
        io << seconds // 3600 << ':' << ((seconds % 3600) // 60).to_s.rjust(2, '0') << ':' << (seconds % 60).to_s.rjust(2, '0')
        io << '.' << microseconds.to_s.rjust(6, '0') if microseconds != 0
      end

      def repr : String
        parts = [] of String
        parts << "days=#{days}" if days != 0
        parts << "seconds=#{seconds}" if seconds != 0
        parts << "microseconds=#{microseconds}" if microseconds != 0
        "datetime.timedelta(#{parts.join(", ")})"
      end

      # Real ansible-core refuses to store a timedelta as a variable value.
      def to_json_any : JSON::Any
        raise KrikriJinja::TemplateError.new("Type 'timedelta' is unsupported for variable storage.", 0)
      end

      def get_attr(name : String) : AnyValue?
        case name
        when "days"         then AnyValue.new(days)
        when "seconds"      then AnyValue.new(seconds)
        when "microseconds" then AnyValue.new(microseconds)
        when "total_seconds"
          AnyValue.new(KrikriJinja::SimpleCallable.new(name) { |_args, _kwargs, _ctx|
            AnyValue.new(@micros / MICROS_PER_SECOND)
          })
        end
      end

      def binary_op(op : String, other : AnyValue, reflected : Bool) : AnyValue?
        other_raw = other.raw
        case op
        when "+"
          other_raw.is_a?(TimeDelta) ? delta(@micros + other_raw.micros) : nil
        when "-"
          return nil unless other_raw.is_a?(TimeDelta)
          delta(reflected ? other_raw.micros - @micros : @micros - other_raw.micros)
        when "*"
          case other_raw
          when Int64   then delta(@micros * other_raw)
          when Float64 then delta((@micros * other_raw).round(mode: :ties_even).to_i64)
          end
        when "/"
          return nil if reflected
          case other_raw
          when TimeDelta then AnyValue.new(@micros / other_raw.micros)
          when Int64     then delta((@micros / other_raw).round(mode: :ties_even).to_i64)
          when Float64   then delta((@micros / other_raw).round(mode: :ties_even).to_i64)
          end
        when "//"
          return nil if reflected
          case other_raw
          when TimeDelta then AnyValue.new(@micros // other_raw.micros)
          when Int64     then delta(@micros // other_raw)
          end
        end
      end

      def compare(other : AnyValue) : Int32?
        other.raw.as?(TimeDelta).try { |span| @micros <=> span.micros }
      end

      def truthy? : Bool
        @micros != 0
      end

      private def delta(micros : Int64) : AnyValue
        AnyValue.new(TimeDelta.new(micros))
      end
    end

    def self.micros_between(from : Time, to : Time) : Int64
      (to - from).total_nanoseconds.to_i64 // 1000
    end

    def self.text(value : AnyValue) : String
      value.raw.as?(String) || KrikriJinja.stringify(value)
    end

    # Python's `datetime.strptime`: the whole string must match the format.
    def self.strptime(text : String, format : String) : DateTime
      DateTime.new(Time.parse(text, format, Time::Location::UTC))
    rescue Time::Format::Error
      raise KrikriJinja::TemplateError.new("time data '#{text}' does not match format '#{format}'", 0)
    end

    def self.register : Nil
      KrikriJinja.register_default_filter("to_datetime") do |value, args, kwargs, _ctx|
        format = text(args[0]? || kwargs["format"]? || AnyValue.new("%Y-%m-%d %H:%M:%S"))
        AnyValue.new(strptime(text(value), format))
      end

      # Ansible's `now(utc=False, fmt=None)` global.
      KrikriJinja.register_default_function("now") do |args, kwargs, _ctx|
        utc = KrikriJinja.truthy?(args[0]? || kwargs["utc"]? || AnyValue.new(false))
        current = utc ? Time.utc : Time.local
        naive = Time.utc(current.year, current.month, current.day, current.hour, current.minute, current.second,
          nanosecond: (current.nanosecond // 1000) * 1000)
        fmt = args[1]? || kwargs["fmt"]?
        if fmt && !fmt.raw.nil?
          AnyValue.new(naive.to_s(text(fmt)))
        else
          AnyValue.new(DateTime.new(naive))
        end
      end
    end
  end
end

Krikri::JinjaDateTime.register
