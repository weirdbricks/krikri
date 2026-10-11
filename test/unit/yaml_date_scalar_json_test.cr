require "../minitest_helper"
require "yaml"
require "json"
require "../../src/krikri/python_yaml_time"

# PyYAML resolves an unquoted date-like YAML scalar (`2026-03-10`) into a
# real Python datetime.date, whose str() is the scalar text itself, while
# Crystal's YAML parser resolves the same scalar to a Time whose to_json
# renders the ISO-Z form "2026-03-10T00:00:00Z" - a text Python never
# produces. That divergence surfaced as round 5460281's HTTP 400 from the
# GitHub API: perimeterd.perimeterd's literal header
# `X-GitHub-Api-Version: 2026-03-10` reached the wire as
# "2026-03-10T00:00:00Z" under krikri, while real ansible-playbook 2.19.11
# sent "2026-03-10" and succeeded. These specs pin the Python-compatible
# text for every shape Crystal's parser resolves to a Time, plus the
# YAML::Any#to_json override the parser's vars/params conversions ride on.

describe "Krikri.python_yaml_time_text" do
  it "renders a date-only scalar as Python str(date)" do
    time = YAML.parse("a: 2026-03-10")["a"].as_time
    Krikri.python_yaml_time_text(time).must_equal("2026-03-10")
  end

  it "renders a naive datetime as Python str(datetime)" do
    time = YAML.parse("a: 2026-03-10 10:30:45")["a"].as_time
    Krikri.python_yaml_time_text(time).must_equal("2026-03-10 10:30:45")
  end

  it "renders a nonzero-UTC-offset datetime with Python's +HH:MM suffix" do
    time = YAML.parse("a: 2026-03-10 10:30:45+02:00")["a"].as_time
    Krikri.python_yaml_time_text(time).must_equal("2026-03-10 10:30:45+02:00")
  end

  it "renders a negative-UTC-offset datetime with Python's -HH:MM suffix" do
    time = YAML.parse("a: 2026-03-10 10:30:45-05:00")["a"].as_time
    Krikri.python_yaml_time_text(time).must_equal("2026-03-10 10:30:45-05:00")
  end

  it "renders fractional seconds with Python's 6-digit microseconds" do
    time = YAML.parse("a: 2026-03-10 10:30:45.123")["a"].as_time
    Krikri.python_yaml_time_text(time).must_equal("2026-03-10 10:30:45.123000")
  end
end

describe "YAML::Any#to_json Python date scalar parity" do
  it "encodes a date-only scalar as its own text, not the ISO-Z form" do
    YAML.parse("a: 2026-03-10")["a"].to_json.must_equal("\"2026-03-10\"")
  end

  it "encodes a nested dict/list date scalar through params-style conversion" do
    doc = YAML.parse("headers:\n  X-GitHub-Api-Version: 2026-03-10\n  Accept: application/vnd.github+json")
    doc["headers"].to_json.must_equal(
      %({"X-GitHub-Api-Version":"2026-03-10","Accept":"application/vnd.github+json"}))
  end

  it "leaves plain string/number scalars untouched" do
    doc = YAML.parse("a: hello\nb: 7\nc: true")
    doc["a"].to_json.must_equal("\"hello\"")
    doc["b"].to_json.must_equal("7")
    doc["c"].to_json.must_equal("true")
  end
end
