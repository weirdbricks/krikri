require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/task_executor/result_display"
require "../../src/krikri/task_executor/output_routing"
require "../../src/krikri/run_options"

# Regression tests for the -v/-vv/-vvv console-output parity work:
# the inline result dumps real ansible-playbook appends to ok/changed/
# skipping lines at verbosity >= 1, the -vvv pretty-dump switch, and the
# play-level source stamping that feeds the Gathering Facts
# `task path:` line. Expected strings captured from real ansible-core
# 2.19.11 runs (ANSIBLE_NOCOLOR=1).
private def capture_output(&)
  io = IO::Memory.new
  Krikri::OutputRouting.redirect_current_fiber_to(io)
  begin
    yield
  ensure
    Krikri::OutputRouting.clear_current_fiber_redirect
  end
  io.to_s
end

describe "verbose output parity" do
  # RunOptions.verbosity is process-wide class state - serialize.
  serial!

  @@saved_verbosity : Int32 = 0

  before_each do
    @@saved_verbosity = Krikri::RunOptions.verbosity
  end

  after_each do
    Krikri::RunOptions.verbosity = @@saved_verbosity
  end

  def host
    Krikri::Host.new("localhost")
  end

  describe ".skip_line_suffix" do
    it "returns nothing at default verbosity" do
      Krikri::RunOptions.verbosity = 0
      Krikri::ResultDisplay.skip_line_suffix("false").must_equal("")
    end

    it "dumps a literal false when: as unquoted false at -v" do
      Krikri::RunOptions.verbosity = 1
      Krikri::ResultDisplay.skip_line_suffix("false").must_equal(%( => {"false_condition": false}))
    end

    it "dumps a string when: condition with its quotes" do
      Krikri::RunOptions.verbosity = 1
      Krikri::ResultDisplay.skip_line_suffix("flag").must_equal(%( => {"false_condition": "flag"}))
    end

    it "adds the loop item to a looped skip dump" do
      Krikri::RunOptions.verbosity = 1
      Krikri::ResultDisplay.skip_line_suffix("false", JSON::Any.new("a")).must_equal(%( => {"false_condition": false, "item": "a"}))
    end

    it "dumps the all-items-skipped trailing shape" do
      Krikri::RunOptions.verbosity = 1
      Krikri::ResultDisplay.skip_line_suffix(all_skipped: true).must_equal(%( => {"changed": false, "msg": "All items skipped"}))
    end

    it "returns nothing when there is no condition and no item" do
      Krikri::RunOptions.verbosity = 1
      Krikri::ResultDisplay.skip_line_suffix.must_equal("")
    end

    it "pretty-dumps at -vvv" do
      Krikri::RunOptions.verbosity = 3
      Krikri::ResultDisplay.skip_line_suffix("false").must_equal(%( => {\n    "false_condition": false\n}))
    end
  end

  describe ".skip_result_suffix" do
    it "strips skipped/failed/invocation keys at -v" do
      Krikri::RunOptions.verbosity = 1
      result = JSON.parse(%({"changed": false, "failed": false, "skipped": true, "invocation": {"module_args": {}}, "cmd": ["echo"], "msg": "Command would have run if not in check mode"}))
      Krikri::ResultDisplay.skip_result_suffix(result).must_equal(%( => {"changed": false, "cmd": ["echo"], "msg": "Command would have run if not in check mode"}))
    end

    it "keeps invocation and pretty-dumps at -vvv" do
      Krikri::RunOptions.verbosity = 3
      result = JSON.parse(%({"changed": false, "failed": false, "skipped": true, "invocation": {"module_args": {}}, "cmd": ["echo"]}))
      Krikri::ResultDisplay.skip_result_suffix(result).must_equal(%( => {\n    "changed": false,\n    "cmd": [\n        "echo"\n    ],\n    "invocation": {\n        "module_args": {}\n    }\n}))
    end

    it "merges ansible_loop_var and the item for a looped skip" do
      Krikri::RunOptions.verbosity = 1
      result = JSON.parse(%({"changed": false, "skipped": true}))
      Krikri::ResultDisplay.skip_result_suffix(result, JSON::Any.new("a")).must_equal(%( => {"ansible_loop_var": "item", "changed": false, "item": "a"}))
    end
  end

  describe ".display_result at verbosity >= 1" do
    it "appends a single-line sorted dump to an ok line at -v" do
      Krikri::RunOptions.verbosity = 1
      result = JSON.parse(%({"changed": false, "rc": 0, "stdout": "hello"}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.command") }
      out.must_equal(%(ok: [localhost] => {"changed": false, "rc": 0, "stdout": "hello"}\n))
    end

    it "merges loop keys into a looped ok dump" do
      Krikri::RunOptions.verbosity = 1
      result = JSON.parse(%({"changed": false, "msg": ""}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, item_label: "x", module_name: "ansible.builtin.command", loop_item: JSON::Any.new("x")) }
      out.must_equal(%(ok: [localhost] => (item=x) => {"ansible_loop_var": "item", "changed": false, "item": "x", "msg": ""}\n))
    end

    it "appends no dump to an ok line at default verbosity" do
      Krikri::RunOptions.verbosity = 0
      result = JSON.parse(%({"changed": false, "rc": 0}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.command") }
      out.must_equal("ok: [localhost]\n")
    end

    it "pretty-dumps an ok line at -vvv and keeps invocation" do
      Krikri::RunOptions.verbosity = 3
      result = JSON.parse(%({"changed": false, "invocation": {"module_args": {"x": 1}}, "rc": 0}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.command") }
      out.must_equal(%(ok: [localhost] => {\n    "changed": false,\n    "invocation": {\n        "module_args": {\n            "x": 1\n        }\n    },\n    "rc": 0\n}\n))
    end
  end

  describe "play source stamping" do
    it "stamps each play with its YAML start line for the Gathering Facts task path" do
      yaml = %(---\n- hosts: localhost\n  gather_facts: false\n  tasks:\n    - name: t\n      debug:\n        msg: hi\n)
      playbook = Krikri::PlaybookParser.parse_string(yaml, "/tmp/kpg-test-play.yml")
      playbook.plays.first.source_line.must_equal(2)
      playbook.plays.first.source_file.must_equal("/tmp/kpg-test-play.yml")
    end
  end
end
