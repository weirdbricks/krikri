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
# The child is a real session leader with the pty slave as its
# controlling terminal (manual `fork()` + `setsid()` +
# `ioctl(TIOCSCTTY)`, not `Process.new` - Crystal's own Process spawn has
# no hook to run code between fork and exec) - matches what a real
# interactive shell session looks like to a program that checks
# `tcgetpgrp()`/job-control signals, not just `isatty()`.
#
# Parameters:
#   command (required): command to run
#   responses (required): {"prompt regex" => "response"} - a list value
#     cycles through each answer in order as the SAME prompt reappears
#     (real Ansible's own repeated-prompt idiom, e.g. confirming several
#     independent items one at a time)
#   timeout (optional, default 30): overall seconds before giving up
#   echo (optional, default false): whether sent responses are echoed by
#     the pty back into the captured output/log - real Ansible's own
#     default is to NOT echo (e.g. so a password response isn't captured)
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
  fun setsid : PidT
  fun ioctl(fd : Int, request : ULong, arg : Int) : Int
end

# TIOCSCTTY (Linux asm-generic/ioctls.h) - makes the calling (session-
# leader) process's open fd its controlling terminal. `arg: 0` means
# "don't steal it from another session" (only relevant if some other
# process already has it, which can't happen for a freshly allocated
# pty).
TIOCSCTTY = 0x540E_u64

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
      echo = @params["echo"]?.try { |v| ["true", "yes", "1"].includes?(v.downcase) } || false

      run_expect(command, responses, timeout, chdir, echo)
    end

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

    private def run_expect(command : String, responses : Array({Regex, Array(String)}), timeout : Int32, chdir : String?, echo : Bool) : PluginResult
      amaster = uninitialized LibC::Int
      aslave = uninitialized LibC::Int
      ret = LibPty.openpty(pointerof(amaster), pointerof(aslave), Pointer(LibC::Char).null, Pointer(Void).null, Pointer(Void).null)
      return PluginResult.new(changed: false, failed: true, msg: "failed to allocate a pty (openpty errno #{Errno.value})") if ret != 0

      slave_io = IO::FileDescriptor.new(aslave, blocking: true)
      # Real Ansible's own default (echo: no) means a sent response's text
      # is NOT echoed back into the captured output - turn off the pty's
      # canonical-mode local echo unless the task explicitly asked for it
      # (echo: true), matching pexpect's own `setecho()` behavior.
      echo ? slave_io.echo! : slave_io.noecho!

      full_command = chdir ? "cd #{shell_quote(chdir)} && #{command}" : command

      pid = LibC.fork
      case pid
      when 0
        # Child: become a session leader and make the pty slave this
        # session's controlling terminal (a plain inherited fd to a tty,
        # with no setsid()/TIOCSCTTY, is never automatically one) -
        # matches what a real interactive shell session looks like to a
        # program checking tcgetpgrp()/expecting job-control signals to
        # work, which `Process.new`'s own spawn (used before this fix)
        # has no hook to arrange between fork and exec.
        LibC.setsid
        LibC.ioctl(aslave, TIOCSCTTY, 0)
        LibC.dup2(aslave, 0)
        LibC.dup2(aslave, 1)
        LibC.dup2(aslave, 2)
        LibC.close(amaster)
        LibC.close(aslave) if aslave > 2

        argv_strs = ["/bin/sh", "-c", full_command]
        argv = Pointer(LibC::Char*).malloc(argv_strs.size + 1)
        argv_strs.each_with_index { |s, i| argv[i] = s.to_unsafe }
        argv[argv_strs.size] = Pointer(LibC::Char).null
        LibC.execvp("/bin/sh", argv)
        LibC._exit(127) # only reached if execvp itself failed
      when -1
        return PluginResult.new(changed: false, failed: true, msg: "failed to fork (errno #{Errno.value})")
      end

      # Parent from here on. `pid` is the child's real pid (fork()
      # returns the child's pid to the parent, 0 to the child - the
      # `when 0` branch above always exits/execs and never falls through
      # to here).
      child_pid = pid
      LibC.close(aslave)

      master_io = IO::FileDescriptor.new(amaster, blocking: true)

      buffer = IO::Memory.new
      # Per-pattern (next unsent answer index, search offset) - the
      # search offset advances past each match so a still-visible earlier
      # occurrence in the ever-growing buffer never re-triggers, while a
      # GENUINELY new occurrence of the same prompt (the real-world case
      # a list of responses exists for - the same confirmation prompt
      # appearing once per item) is still found and answered with the
      # next entry in its list, cycling through it in order.
      search_from = Array.new(responses.size, 0)
      next_answer = Array.new(responses.size, 0)
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
          next if next_answer[idx] >= answers.size
          next unless md = pattern.match(text, search_from[idx])

          payload = (answers[next_answer[idx]] + "\n").to_slice
          LibC.write(amaster, payload.to_unsafe, payload.size)
          next_answer[idx] += 1
          search_from[idx] = md.end(0)
        end
      end

      LibC.kill(child_pid, Signal::TERM.value) rescue nil
      raw_status = uninitialized LibC::Int
      LibC.waitpid(child_pid, pointerof(raw_status), 0)
      status = Process::Status.new(raw_status)
      master_io.close rescue nil

      output = buffer.to_s

      PluginResult.new(
        changed: true,
        failed: !status.success?,
        msg: timed_out ? "timed out waiting for a matching prompt" : "",
        stdout: output,
        rc: status.exit_code? || -1
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
