require "../minitest_helper"
require "../../src/krikri/task_executor/output_routing"
require "../../src/krikri/task_executor/error_block"

# Ansible's `Display.display` rewrites every CRLF in a message to a bare
# LF before writing it, and display() is the one choke point all of its
# console output passes through. Messages whose own PAYLOAD carries CRLF
# (an unreachable report's ssh stderr: the known-hosts warning line plus
# the `user@host: Permission denied (...)` line) therefore reach the
# terminal with plain newlines. krikri wrote the raw bytes, so on a tty
# the CRLF inside the message became `\r\r\n` and the block came out one
# byte longer than real's - issue #975's divergence.
describe "display CRLF normalization" do
  # The two-line ssh stderr from the issue, SSH's own text with CRLF.
  SSH_STDERR_MSG = "Task failed: Failed to connect to the host via ssh: Warning: Permanently added '[10.0.0.5]:2222' (ED25519) to the list of known hosts.\r\ncore@10.0.0.5: Permission denied (publickey,password)."

  it "reduces a CRLF inside a message to a bare LF" do
    Krikri::OutputRouting.normalize_for_display("a\r\nb\r\nc").must_equal("a\nb\nc")
  end

  it "leaves a message with no CRLF untouched" do
    Krikri::OutputRouting.normalize_for_display("a\nb\rc").must_equal("a\nb\rc")
  end

  it "prints an [ERROR] block with no CR left in it" do
    Krikri::ErrorBlock.reset_seen
    io = IO::Memory.new
    Krikri::ErrorBlock.emit_to(io, Krikri::ErrorBlock::Node.new(SSH_STDERR_MSG))

    io.to_s.must_equal("[ERROR]: #{SSH_STDERR_MSG.gsub("\r\n", '\n')}\n\n")
  end

  it "normalizes a message written through the routed puts" do
    io = IO::Memory.new
    Krikri::OutputRouting.redirect_current_fiber_to(io)
    begin
      puts SSH_STDERR_MSG
    ensure
      Krikri::OutputRouting.clear_current_fiber_redirect
    end

    io.to_s.must_equal("#{SSH_STDERR_MSG.gsub("\r\n", '\n')}\n")
  end
end
