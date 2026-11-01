# community.crypto's _time.py timespec handling, shared by the plugins
# that take a `valid_at`-style time spec (x509_certificate_info) and by
# anything that has to echo what the real module would echo.
#
# _time.py's get_relative_time_option accepts two shapes:
# - a relative sshd_config(5) spec: a leading +/- then weeks/days/hours/
#   minutes/seconds components in that exact order ("+1w", "-2d3h", "+0");
# - one of four absolute shapes: %Y%m%d%H%M%SZ (15), %Y%m%d%H%MZ (13),
#   %Y%m%d%H%M%S%z (19), %Y%m%d%H%M%z (17). A %z offset is normalized to
#   UTC like real's add_or_remove_timezone does.
# Everything else is invalid: a relative-looking failure says
# 'The timespec "..." for <name> is invalid', an absolute-looking one
# 'The time spec "..." for <name> is invalid' - two different words for
# the same idea, kept verbatim.
require "./python_lib_gate"

module Krikri
  module CryptoTimeSpec
    # _time.py's convert_relative_to_datetime pattern, with named groups
    # (the shared RELATIVE_TIME_RE validator in ansible_arg_validation uses
    # unnamed ones, so it can't hand the components over).
    RELATIVE_SPEC_RE = /^[+-](?<weeks>\d+[wW])?(?<days>\d+[dD])?(?<hours>\d+[hH])?(?<minutes>\d+[mM])?(?<seconds>\d+[sS]?)?$/

    # The datetime a spec resolves to, in UTC. nil when the spec matches
    # neither shape (the caller owns the error message: the wording differs
    # between the relative and absolute failure paths).
    def self.resolve(spec : String) : Time?
      if spec.starts_with?('+') || spec.starts_with?('-')
        # A lone "+" or "-" matches the bare regex but real rejects it
        # explicitly (len(relative_time_string) == 1 -> None).
        return nil if spec.size == 1
        match = spec.match(RELATIVE_SPEC_RE)
        return nil unless match
        # Each named group keeps its unit suffix (Python's inner \d+ group
        # is the digits only); strip it before counting.
        weeks = relative_component(match, "weeks")
        days = relative_component(match, "days")
        hours = relative_component(match, "hours")
        minutes = relative_component(match, "minutes")
        seconds = relative_component(match, "seconds")
        offset = (weeks * 7 + days).days + hours.hours + minutes.minutes + seconds.seconds
        spec[0] == '+' ? Time.utc + offset : Time.utc - offset
      else
        case spec.size
        when 15 then parse_time(spec, "%Y%m%d%H%M%SZ")
        when 13 then parse_time(spec, "%Y%m%d%H%MZ")
        when 19 then parse_time(spec, "%Y%m%d%H%M%S%z")
        when 17 then parse_time(spec, "%Y%m%d%H%M%z")
        end
      end
    end

    private def self.relative_component(match : Regex::MatchData, name : String) : Int32
      (match[name]? || "0").rstrip("wWdDhHmMsS").to_i
    end

    private def self.parse_time(value : String, format : String) : Time?
      Time.parse(value, format, Time::Location::UTC).to_utc
    rescue Time::Format::Error | ArgumentError
      nil
    end

    # The wire form a resolved datetime takes in real's echoed
    # invocation.module_args: Python's datetime.isoformat() of a UTC
    # datetime - the fraction is omitted entirely when the microseconds
    # are 0, and with_timezone (community.crypto's CRYPTOGRAPHY_TIMEZONE:
    # cryptography >= 42 on the target) adds Python's own "+00:00" offset
    # spelling.
    def self.echo(time : Time, with_timezone : Bool) : String
      text = time.to_s("%Y-%m-%dT%H:%M:%S")
      # Python datetimes carry microsecond resolution; krikri's Time has
      # nanoseconds, so truncate (datetime.now never rounds up).
      micros = time.nanosecond // 1_000
      text += ".#{micros.to_s.rjust(6, '0')}" if micros != 0
      text += "+00:00" if with_timezone
      text
    end

    # Whether the real module would resolve its "now" as a timezone-aware
    # UTC datetime: CRYPTOGRAPHY_TIMEZONE is cryptography >= 42.0.0 (the
    # version that made datetime.utc* deprecated-aware), False when
    # cryptography is absent or older. Probed through the interpreter the
    # module would run under (python_lib_gate's fallback list; an
    # ansible_python_interpreter pin is not consulted here - get_certificate's
    # target_python precedent). Any probe failure means "not tz-aware",
    # matching CRYPTOGRAPHY_TIMEZONE's False default.
    def self.with_timezone? : Bool
      python = nil
      INTERPRETER_FALLBACK.each do |name|
        if path = Process.find_executable(name)
          python = path
          break
        end
      end
      return false unless python

      io = IO::Memory.new
      probe = "try:\n" \
              "    import cryptography\n" \
              "    parts = cryptography.__version__.split('.')\n" \
              "    print('tz' if (int(parts[0]), int(parts[1])) >= (42, 0) else 'naive')\n" \
              "except Exception:\n" \
              "    print('naive')\n"
      status = Process.run(python, {"-c", probe}, output: io, error: Process::Redirect::Close)
      status.success? && io.to_s.strip == "tz"
    rescue
      false
    end

    # The `{type(v)}` spelling real's "must be of type string" failure
    # interpolates: the module args arrive as JSON, so the Python type the
    # module would see is the JSON value's class.
    def self.python_type_name(value : JSON::Any) : String
      case value.raw
      when Int64, Int32
        "<class 'int'>"
      when Float64
        "<class 'float'>"
      when Bool
        "<class 'bool'>"
      when Nil
        "<class 'NoneType'>"
      when Array
        "<class 'list'>"
      else
        "<class 'dict'>"
      end
    end
  end
end
