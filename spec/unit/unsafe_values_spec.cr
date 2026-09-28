require "../spec_helper"
require "../../src/krikri/unsafe_values"
require "c/unistd"

lib LibC
  fun dup(oldfd : Int32) : Int32
end

# Test-only override of UnsafeValues.walk: byte-for-byte the real walker
# except that a scalar tagged `!unsafe` whose text is the sentinel
# RECORDS itself first and then raises a non-parse exception, aborting
# the walk mid-document. This is the stubbed trigger for the
# "parseable document, walk blows up partway" case - real YAML cannot
# produce it (Crystal's pull parser caps nesting at 513 with a
# YAML::ParseException, and unknown aliases also raise
# YAML::ParseException), so no genuine input can be used.
module Krikri
  module UnsafeValues
    private def self.walk(parser : YAML::PullParser) : Nil
      loop do
        case parser.kind
        when .scalar?
          tag = parser.tag
          value = parser.read_scalar
          if tag == "!unsafe"
            @@texts.add(value)
            raise Exception.new("simulated mid-walk failure") if value == "MARKED_BEFORE_FAILURE"
          end
        when .sequence_start?
          parser.read_sequence_start
          walk(parser)
        when .mapping_start?
          parser.read_mapping_start
          walk(parser)
        when .sequence_end?, .mapping_end?
          parser.read_next
          return
        when .alias?
          parser.read_alias
        else
          return
        end
      end
    end
  end
end

def capture_stderr(&)
  saved_fd = LibC.dup(STDERR.fd)
  err_file = File.tempfile("krikri-spec-stderr")
  STDERR.reopen(err_file)
  begin
    yield
    err_file.rewind
    err_file.gets_to_end
  ensure
    if saved_fd >= 0
      # Close through the wrapper, never LibC.close: a wrapper whose fd was
      # closed behind its back still closes that fd NUMBER from its GC
      # finalizer later - by then reused by some other test's pipe/file
      # (EBADF on close, dup2 failures in Process.new children).
      saved = IO::FileDescriptor.new(saved_fd)
      STDERR.reopen(saved)
      saved.close
    end
    err_file.try(&.close)
  end
end

describe Krikri::UnsafeValues do
  describe ".mark_yaml_text" do
    it "degrades to a partial walk with a warning when a parseable document fails mid-walk" do
      doc = %(key1: !unsafe "MARKED_BEFORE_FAILURE"\nkey2: !unsafe "MARKED_AFTER_FAILURE"\n)

      stderr = capture_stderr do
        Krikri::UnsafeValues.mark_yaml_text(doc)
      end

      Krikri::UnsafeValues.unsafe_text?("MARKED_BEFORE_FAILURE").should be_true
      Krikri::UnsafeValues.unsafe_text?("MARKED_AFTER_FAILURE").should be_false
      stderr.should contain("!unsafe pre-scan aborted mid-document")
      stderr.should contain("simulated mid-walk failure")
      stderr.should contain("key1: !unsafe")
    end

    it "still records !unsafe scalars in a document whose walk succeeds" do
      doc = %(a: !unsafe "plain-walk-success-sentinel"\nb: ok\n)

      Krikri::UnsafeValues.mark_yaml_text(doc)

      Krikri::UnsafeValues.unsafe_text?("plain-walk-success-sentinel").should be_true
      Krikri::UnsafeValues.unsafe_text?("ok").should be_false
    end

    it "stays silent for a malformed document (the real parse reports it)" do
      doc = %(a: !unsafe "broken\n  b: [unclosed\n)

      stderr = capture_stderr do
        Krikri::UnsafeValues.mark_yaml_text(doc)
      end

      stderr.should be_empty
    end
  end
end
