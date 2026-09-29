require "../minitest_helper"
require "../../src/krikri/output_banner"
require "../../src/krikri/task_executor/output_routing"
require "../../src/krikri/task_executor/result_display"

# Byte-level output-parity regression tests for the console shapes shared
# with real ansible-playbook (ansible-core 2.19.11). The exact expected
# strings here were captured from real ansible-playbook runs (non-tty,
# ANSIBLE_NOCOLOR=1) via scripts/output_parity.sh.
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

describe Krikri::OutputBanner do
  describe ".stars" do
    # Real's banner pads to a fixed display width of 79 columns when
    # stdout is not a tty: star count = 79 - len(msg), so "PLAY RECAP"
    # (10 chars) gets 69 stars and the full line is 80 columns.
    it "pads PLAY RECAP to the non-tty 79-column width" do
      Krikri::OutputBanner.stars("PLAY RECAP").must_equal("*" * 69)
    end

    it "pads a PLAY line to the same total width" do
      msg = "PLAY [Debug Test]"
      Krikri::OutputBanner.stars(msg).must_equal("*" * (79 - msg.size))
    end

    it "never emits fewer than three stars for a very long message" do
      Krikri::OutputBanner.stars("x" * 200).must_equal("***")
    end
  end

  describe ".banner" do
    # Real's banner output is "\n<msg> <stars>\n": one leading blank
    # line, then the padded line. Banners are never colorized.
    it "prints a blank line then the padded banner line" do
      out = capture_output { Krikri::OutputBanner.banner("PLAY RECAP") }
      out.must_equal("\nPLAY RECAP #{"*" * 69}\n")
    end
  end
end

describe Krikri::ResultDisplay do
  describe ".show_recap" do
    # Byte-for-byte against real ansible-playbook's v2_playbook_on_stats
    # (non-tty): host padded to 26, then " : ", then the seven counters
    # each shaped `lead=%-4s` joined by single spaces - trailing padding
    # included on the last counter.
    it "pads the host column to 26 and every counter to 4" do
      host = Krikri::Host.new("localhost")
      stats = {"ok" => 4, "changed" => 1, "unreachable" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0}
      out = capture_output { Krikri::ResultDisplay.show_recap([host], {"localhost" => stats}) }
      out.must_equal("localhost                  : ok=4    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   \n")
    end

    it "keeps multi-digit counters left-justified in the same 4-slot field" do
      host = Krikri::Host.new("web1")
      stats = {"ok" => 44, "changed" => 6, "unreachable" => 0, "failed" => 0, "skipped" => 5, "rescued" => 0, "ignored" => 0}
      out = capture_output { Krikri::ResultDisplay.show_recap([host], {"web1" => stats}) }
      out.must_equal("web1                       : ok=44   changed=6    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0   \n")
    end

    it "prints a zeroed recap line for a host with no results" do
      host = Krikri::Host.new("db1")
      out = capture_output { Krikri::ResultDisplay.show_recap([host], {} of String => Hash(String, Int32)) }
      out.must_equal("db1                        : ok=0    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   \n")
    end
  end

  describe ".display_result" do
    def host
      Krikri::Host.new("localhost")
    end

    # Real's default callback appends the pretty-sorted result dump after
    # " => " on the status line itself (not on a following line).
    it "dumps a debug msg result inline after '=> ' without a changed key" do
      result = JSON.parse(%({"changed": false, "msg": "Output was: Hello World", "_ansible_verbose_always": true}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.debug") }
      out.must_equal("ok: [localhost] => {\n    \"msg\": \"Output was: Hello World\"\n}\n")
    end

    it "dumps a debug var result inline after '=> ' without a changed key" do
      result = JSON.parse(%({"changed": false, "test_result.stdout": "Hello World", "_ansible_verbose_always": true}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.debug") }
      out.must_equal("ok: [localhost] => {\n    \"test_result.stdout\": \"Hello World\"\n}\n")
    end

    it "keeps the changed key for a non-debug verbose-always result (assert shape)" do
      result = JSON.parse(%({"changed": false, "msg": "All assertions passed", "_ansible_verbose_always": true}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.assert") }
      out.must_equal("ok: [localhost] => {\n    \"changed\": false,\n    \"msg\": \"All assertions passed\"\n}\n")
    end

    it "prints only the status line for a non-verbose successful result" do
      result = JSON.parse(%({"changed": false, "msg": "Command executed successfully"}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, module_name: "ansible.builtin.command") }
      out.must_equal("ok: [localhost]\n")
    end

    it "formats a looped verbose result as 'ok: [host] => (item=x) => {json}'" do
      result = JSON.parse(%({"changed": false, "msg": "loop item: a", "_ansible_verbose_always": true}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false, item_label: "a", module_name: "ansible.builtin.debug") }
      out.must_equal("ok: [localhost] => (item=a) => {\n    \"msg\": \"loop item: a\"\n}\n")
    end

    it "keeps the single-line fatal dump for a failed non-loop result" do
      result = JSON.parse(%({"changed": true, "failed": true, "msg": "non-zero return code", "rc": 1}))
      out = capture_output { Krikri::ResultDisplay.display_result(host, result, false) }
      out.must_equal("fatal: [localhost]: FAILED! => {\"changed\": true, \"msg\": \"non-zero return code\", \"rc\": 1}\n")
    end
  end
end
