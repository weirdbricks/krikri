require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"
require "../../src/krikri/variable_substitutor"
require "file_utils"
require "c/unistd"

lib LibC
  fun dup(oldfd : Int32) : Int32
end

# Like unsafe_values_test.cr's capture_stderr, uniquely named so both can
# coexist in the generated suite entrypoint.
private def capture_stderr_fd(&)
  saved_fd = LibC.dup(STDERR.fd)
  err_file = File.tempfile("krikri-capture-stderr")
  STDERR.reopen(err_file)
  begin
    value = yield
    err_file.rewind
    {value, err_file.gets_to_end}
  ensure
    if saved_fd >= 0
      saved = IO::FileDescriptor.new(saved_fd)
      STDERR.reopen(saved)
      saved.close
    end
    err_file.try(&.close)
  end
end

# Issue #489: batch-build prepares every group member up front, so a later
# member's jinja-constant warning fired during batch-build - ahead of
# earlier members' output and even for a task an earlier member's failure
# keeps the play from ever reaching. ResultDisplay.capture_stderr_warnings
# is the capture primitive both warning emitters route through; these tests
# pin its contract: captured text is returned and STDERR stays silent, the
# uncaptured path still writes STDERR, nesting keeps each capture's own
# text, and the jinja-constant block is captured like any other warning.
describe Krikri::ResultDisplay do
  serial! # capture_stderr_fd mutates process-global state (STDERR itself)

  describe ".capture_stderr_warnings" do
    it "returns the warning text and leaves STDERR silent while active" do
      captured, stderr = capture_stderr_fd do
        Krikri::ResultDisplay.capture_stderr_warnings do
          Krikri::ResultDisplay.emit_display_warning("capture-test multi-line\nbody line")
        end
      end

      captured.must_include("[WARNING]: capture-test multi-line")
      captured.must_include("body line")
      # Ansible's format_event ends a multi-line warning with a blank line -
      # the capture must carry it exactly as the uncaptured write would.
      captured.ends_with?("body line\n\n").must_equal(true)
      stderr.must_be_empty
    end

    it "still writes STDERR when no capture is active" do
      _, stderr = capture_stderr_fd do
        Krikri::ResultDisplay.emit_display_warning("uncaptured-test warning")
      end

      stderr.must_include("[WARNING]: uncaptured-test warning")
    end

    it "gives a nested capture only its own text" do
      inner_text = ""
      outer_text = ""
      _, stderr = capture_stderr_fd do
        outer_text = Krikri::ResultDisplay.capture_stderr_warnings do
          Krikri::ResultDisplay.emit_display_warning("outer-nested warning")
          inner_text = Krikri::ResultDisplay.capture_stderr_warnings do
            Krikri::ResultDisplay.emit_display_warning("inner-nested warning")
          end
        end
      end

      inner_text.must_include("inner-nested warning")
      inner_text.wont_include("outer-nested warning")
      outer_text.must_include("outer-nested warning")
      outer_text.wont_include("inner-nested warning")
      stderr.must_be_empty
    end

    it "captures the jinja-constant embedded-template warning block" do
      src_dir = File.tempname("jinja-const-capture")
      Dir.mkdir_p(src_dir)
      pb_path = File.join(src_dir, "pb.yml")
      File.write(pb_path, <<-YAML)
        ---
        - hosts: localhost
          gather_facts: false
          tasks:
            - authorized_key:
                user: root
                key: "{{ lookup('file', '{{ local_public_key }}') }}"
        YAML
      key_line = File.read_lines(pb_path).index! { |line| line.strip.starts_with?("key:") } + 1

      captured, stderr = capture_stderr_fd do
        Krikri::VarSubstitutor.set_current_task_param(pb_path, key_line, "key")
        begin
          Krikri::ResultDisplay.capture_stderr_warnings do
            Krikri::VariableSubstitutor::ExpressionEvaluator.emit_jinja_const_template_warning
          end
        ensure
          Krikri::VarSubstitutor.pop_current_task_param
        end
      end

      captured.must_include("[WARNING]: Jinja constant strings should not contain embedded templates")
      captured.must_include("Origin: #{pb_path}:")
      captured.must_include("Use inline expressions")
      stderr.must_be_empty
    ensure
      FileUtils.rm_rf(src_dir) if src_dir
    end
  end
end
