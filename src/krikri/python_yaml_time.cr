require "yaml"
require "json"

module Krikri
  # PyYAML resolves an unquoted date-like YAML scalar the way YAML 1.1's
  # core schema says (`X-GitHub-Api-Version: 2026-03-10` arrives as a real
  # Python datetime.date, round 5460281), and every place Python then turns
  # one into text - a templated render, an HTTP header value, a JSON dump -
  # produces str(date)/str(datetime): "2026-03-10" for a date-only scalar,
  # "%Y-%m-%d %H:%M:%S" (microseconds only when nonzero, "+HH:MM" only when
  # tz-aware) for a full timestamp. Crystal's YAML parser resolves the same
  # scalars to a Time, whose own to_json/to_s render ISO-Z forms
  # ("2026-03-10T00:00:00Z") Python never produces - the exact divergence
  # that made krikri's GitHub API request fail HTTP 400 where real
  # ansible-playbook succeeded.
  #
  # A date-only scalar and a naive midnight datetime both arrive here as a
  # zero-offset UTC-midnight Time and are indistinguishable after the parse,
  # so the date-only form is chosen for that shape (the overwhelmingly
  # common YAML usage; a literal `2026-03-10 00:00:00` is vanishingly rare
  # and only its seconds text diverges).
  def self.python_yaml_time_text(time : Time) : String
    if time.offset == 0 && time.hour == 0 && time.minute == 0 &&
       time.second == 0 && time.nanosecond == 0
      return time.to_s("%Y-%m-%d")
    end

    text = time.to_s("%Y-%m-%d %H:%M:%S")
    micros = time.nanosecond // 1_000
    text += ".#{micros.to_s.rjust(6, '0')}" if micros != 0
    offset = time.offset
    if offset != 0
      sign = offset >= 0 ? "+" : "-"
      abs = offset.abs
      text += "#{sign}#{(abs // 3600).to_s.rjust(2, '0')}:#{((abs % 3600) // 60).to_s.rjust(2, '0')}"
    end
    text
  end
end

# The parser (and every other main-binary YAML -> JSON hop: vars, loops,
# from_yaml/to_json filters) converts YAML::Any trees with a plain
# `to_json`, so redefining the one scalar case that diverges - Time, which
# stdlib renders through Time's ISO-8601 JSON form - makes every converted
# date/time scalar carry Python's str() text instead. previous_def keeps
# the stdlib body for every non-Time value.
struct YAML::Any
  def to_json(builder : JSON::Builder) : Nil
    if (raw = @raw).is_a?(Time)
      Krikri.python_yaml_time_text(raw).to_json(builder)
    else
      previous_def
    end
  end
end
