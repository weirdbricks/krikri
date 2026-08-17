#!/usr/bin/env crystal

# expect module (ansible.builtin.expect) - runs an interactive command
# attached to a real pty and answers prompts matching `responses:`
# patterns as they appear, same category of problem real Ansible's own
# module solves via pexpect. No pexpect equivalent exists for Crystal, so
# this talks to the kernel pty layer directly via `openpty(3)` (glibc,
# -lutil) rather than shelling out to a separate `expect(1)` binary -
# keeps this self-contained the same way every other plugin here is (no
# new external dependency on the target beyond what's already required).
#
# Known limitation (documented, not fixed): the child is never made a
# session leader via setsid()/TIOCSCTTY, so real job-control signals
# (Ctrl-C forwarding, a program that explicitly checks for a controlling
# terminal via tcgetpgrp) don't behave exactly like a real interactive
# shell session would. `isatty()` on the slave fd still returns true
# (it's a genuine pty device), which is what most simple Y/N/password
# prompts actually check - the common real-world shape this module
# targets. `echo:` (real Ansible's own termios-level "don't echo the
# typed response back" option, used for passwords) is not implemented -
# a sent response's own text appears in the captured stdout, a cosmetic-
# only gap for the (rare) password-prompt case.
#
# Parameters:
#   command (required): command to run
#   responses (required): {"prompt regex" => "response"} - a list value
#     is accepted (real Ansible's own list-response shape for a prompt
#     that repeats) but only its first entry is ever used; see
#     `answered` below for why repeated-prompt cycling isn't supported
#   timeout (optional, default 30): overall seconds before giving up
#   chdir (optional)
#   creates/removes (optional): idempotency guards, same as command:

require "json"
require "../src/crystal_play/base_plugin"

@[Link("util")]
lib LibPty
  fun openpty = openpty(amaster : LibC::Int*, aslave : LibC::Int*, name : LibC::Char*, termp : Void*, winp : Void*) : LibC::Int
end

lib LibC
  struct Pollfd
    fd : Int32
    events : Int16
    revents : Int16
  end

  fun poll(fds : Pollfd*, nfds : UInt64, timeout : Int32) : Int32
end

module CrystalPlay
  class ExpectPlugin < BasePlugin
    def execute : PluginResult
      command = @params["command"]? || @params["_raw_params"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: command") unless command

      responses_json = @params["responses"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: responses") unless responses_json

      responses = parse_responses(responses_json)
      return PluginResult.new(changed: false, failed: true, msg: "responses must be a dictionary of pattern -> response") unless responses

      if creates = @params["creates"]?
        return PluginResult.new(changed: false, failed: false, msg: "skipped, since #{creates} exists", skipped: true) if remote_file_exists?(expand_tilde(creates))
      end

      if removes = @params["removes"]?
        return PluginResult.new(changed: false, failed: false, msg: "skipped, since #{removes} does not exist", skipped: true) unless remote_file_exists?(expand_tilde(removes))
      end

      timeout = @params["timeout"]?.try(&.to_i?) || 30
      chdir = @params["chdir"]?.try { |c| expand_tilde(c) }

      run_expect(command, responses, timeout, chdir)
    end

    private record ResponseState, patterns : Array({Regex, Array(String)}), answered_at : Hash(Int32, Int32)

    private def parse_responses(json : String) : Array({Regex, Array(String)})?
      parsed = JSON.parse(json) rescue nil
      hash = parsed.try(&.as_h?)
      return nil unless hash

      hash.map do |pattern, value|
        answers = if arr = value.as_a?
                    arr.map(&.as_s)
                  else
                    [value.as_s]
                  end
        {Regex.new(pattern), answers}
      end
    end

    private def run_expect(command : String, responses : Array({Regex, Array(String)}), timeout : Int32, chdir : String?) : PluginResult
      amaster = uninitialized LibC::Int
      aslave = uninitialized LibC::Int
      ret = LibPty.openpty(pointerof(amaster), pointerof(aslave), Pointer(LibC::Char).null, Pointer(Void).null, Pointer(Void).null)
      return PluginResult.new(changed: false, failed: true, msg: "failed to allocate a pty (openpty errno #{Errno.value})") if ret != 0

      # Deliberately raw LibC.poll/read/write on plain OS-blocking fds
      # here, not Crystal's own evented IO::FileDescriptor#read_timeout=/
      # #write - found the hard way that a non-blocking FileDescriptor's
      # #write onto a pty master silently went nowhere (the child's own
      # `read -p` never saw it, no exception raised either) while
      # #read_timeout= itself worked fine; rather than chase that gap
      # further, poll(2) + a plain blocking read()/write() sidesteps
      # Crystal's evented-IO layer for this fd pair entirely - poll
      # gives the same "wait up to N ms for readability" behavior
      # #read_timeout= was for, and a blocking write onto a freshly
      # allocated pty's own kernel buffer (many KB before it'd ever
      # actually block) is safe for the small responses this module
      # sends.
      master_io = IO::FileDescriptor.new(amaster, blocking: true)
      slave_io = IO::FileDescriptor.new(aslave, blocking: true)

      full_command = chdir ? "cd #{shell_quote(chdir)} && #{command}" : command

      process = Process.new(
        "/bin/sh",
        ["-c", full_command],
        input: slave_io,
        output: slave_io,
        error: slave_io
      )
      slave_io.close

      buffer = IO::Memory.new
      # Each response is sent at most once per pattern, ever - not
      # "once per new occurrence of the pattern in the buffer". A
      # substring pattern match against the ever-growing buffer stays
      # true forever once it first appears (the matched text is never
      # removed), and the pty's own canonical-mode echo of whatever we
      # just wrote lands right back in the next read chunk - tracking
      # "have I answered this pattern at all" (not "at this buffer
      # length") avoids re-triggering on that echo and re-sending the
      # same response in a tight loop until the deadline. Real
      # Ansible's own list-of-responses feature (cycling through
      # several answers for a prompt that legitimately repeats) isn't
      # supported here for the same reason - only the first list entry
      # is ever used.
      answered = Set(Int32).new
      deadline = Time.monotonic + timeout.seconds
      chunk = Bytes.new(4096)
      timed_out = false

      loop do
        remaining_ms = (deadline - Time.monotonic).total_milliseconds.to_i
        if remaining_ms <= 0
          timed_out = true
          break
        end

        pfd = LibC::Pollfd.new
        pfd.fd = amaster
        pfd.events = 1_i16 # POLLIN
        pfd.revents = 0_i16
        poll_ret = LibC.poll(pointerof(pfd), 1_u64, remaining_ms)

        if poll_ret == 0
          timed_out = true
          break
        elsif poll_ret < 0
          break
        end

        bytes_read = LibC.read(amaster, chunk.to_unsafe, chunk.size).to_i
        break if bytes_read <= 0

        buffer.write(chunk[0, bytes_read])
        text = buffer.to_s

        responses.each_with_index do |(pattern, answers), idx|
          next if answered.includes?(idx)
          next unless pattern.matches?(text)

          payload = (answers.first + "\n").to_slice
          LibC.write(amaster, payload.to_unsafe, payload.size)
          answered << idx
        end
      end

      process.terminate rescue nil
      status = process.wait rescue nil
      master_io.close rescue nil

      output = buffer.to_s

      PluginResult.new(
        changed: true,
        failed: status.nil? || !status.success?,
        msg: timed_out ? "timed out waiting for a matching prompt" : "",
        stdout: output,
        rc: status.try(&.exit_code?) || -1
      )
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::ExpectPlugin.new(config)
plugin.run
