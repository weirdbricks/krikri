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
# Real expect.py semantics reproduced here (confirmed against real
# ansible-playbook via the expect_edge_cases podman-diff case):
# - command is NOT run through a shell - pexpect shlex-splits it and
#   execs the binary directly, so `$HOME`, `>`, `|` etc. stay literal
#   arguments; a missing executable fails with pexpect's own "The
#   command was not found or was not executable: <first token>."
# - an empty (all-whitespace) command fails with rc=256 "no command
#   given" before chdir/creates are considered
# - creates/removes use plain os.path.exists (NO glob support, unlike
#   the command module) and the skip result carries NO msg - just
#   stdout "skipped, since <path> exists/does not exist", rc=0
# - timeout gives failed "command exceeded timeout" with rc=None and
#   the partial output so far (changed stays true)
# - a STRING response repeats on every prompt match; a LIST response is
#   consumed in order and then EXHAUSTS - fail_json "No remaining
#   responses for '<key>', output was '<text since last match>'"
#   (changed=false, unlike a timeout)
# - non-zero child exit gives "non-zero return code" with changed=true
# - chdir is pexpect's cwd for the spawned command (and, like real's
#   os.chdir, also resolves relative creates/removes)

require "json"
require "../src/krikri/base_plugin"

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

module Krikri
  class ExpectPlugin < BasePlugin
    # (pattern key for real's "No remaining responses for '<key>'" msg,
    # compiled regex, answers, whether the task gave a LIST response)
    alias Response = {String, Regex, Array(String), Bool}

    def execute : PluginResult
      command = @params["command"]? || @params["_raw_params"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: command") unless command

      responses_json = @params["responses"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: responses") unless responses_json

      responses = parse_responses(responses_json)
      return PluginResult.new(changed: false, failed: true, msg: "responses must be a dictionary of pattern -> response") unless responses

      # Real expect.py strips and rejects an empty command with rc=256
      # BEFORE chdir/creates/removes are considered.
      if command.strip.empty?
        return PluginResult.new(changed: false, failed: true, msg: "no command given", rc: 256)
      end

      timeout = @params["timeout"]?.try(&.to_i?) || 30
      chdir = @params["chdir"]?.try { |itm| expand_tilde(itm) }
      echo = @params["echo"]?.try { |v| ["true", "yes", "1"].includes?(v.downcase) } || false

      # Real expect.py os.chdir's the module process before the
      # creates/removes checks, so relative guards resolve against chdir.
      # (Unlike command.py, these are plain os.path.exists - NO glob.)
      guard_base = chdir.try { |dir| File.expand_path(dir) }

      if creates = @params["creates"]?
        if File.exists?(resolve_guard(creates, guard_base))
          return skip_result("skipped, since #{creates} exists")
        end
      end

      if removes = @params["removes"]?
        unless File.exists?(resolve_guard(removes, guard_base))
          return skip_result("skipped, since #{removes} does not exist")
        end
      end

      run_expect(command, responses, timeout, chdir, echo)
    end

    private def parse_responses(json : String) : Array(Response)?
      parsed = JSON.parse(json) rescue nil
      hash = parsed.try(&.as_h?)
      return nil unless hash

      hash.map do |pattern, value|
        if arr = value.as_a?
          {pattern, Regex.new(pattern), arr.map(&.as_s), true}
        else
          # A plain string response repeats on every match (real sends
          # the same static bytes each time).
          {pattern, Regex.new(pattern), [value.as_s], false}
        end
      end
    end

    private def resolve_guard(path : String, guard_base : String?) : String
      expanded = expand_tilde(path)
      return File.expand_path(expanded, guard_base) if guard_base && !expanded.starts_with?('/')

      expanded
    end

    # Real expect.py's skip exits with cmd/stdout/changed/rc only - NO
    # msg (that wording belongs to the command module, not expect.py).
    private def skip_result(stdout : String) : PluginResult
      PluginResult.new(changed: false, failed: false, stdout: stdout, rc: 0)
    end

    private def run_expect(command : String, responses : Array(Response), timeout : Int32, chdir : String?, echo : Bool) : PluginResult
      args = shlex_split(command)
      # pexpect.spawn resolves the executable through PATH and fails with
      # its own ExceptionPexpect wording before anything runs; execvp's
      # own 127-through-shell behavior is a shell expectation, not
      # pexpect's.
      unless which(args[0])
        return PluginResult.new(changed: false, failed: true, msg: "The command was not found or was not executable: #{args[0]}.")
      end

      amaster = uninitialized LibC::Int
      aslave = uninitialized LibC::Int
      ret = LibPty.openpty(pointerof(amaster), pointerof(aslave), Pointer(LibC::Char).null, Pointer(Void).null, Pointer(Void).null)
      return PluginResult.new(changed: false, failed: true, msg: "failed to allocate a pty (openpty errno #{Errno.value})") if ret != 0

      setup_slave_echo(aslave, echo)

      pid = LibC.fork
      case pid
      when 0
        child_exec(args, aslave, amaster, chdir)
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
      timed_out, exhausted, output = read_until_deadline(amaster, responses, Time.monotonic + timeout.seconds)

      LibC.kill(child_pid, Signal::TERM.value) rescue nil
      raw_status = uninitialized LibC::Int
      LibC.waitpid(child_pid, pointerof(raw_status), 0)
      status = Process::Status.new(raw_status)
      master_io.close rescue nil

      # Real rstrip('\r\n')s the accumulated pty output.
      output = output.rstrip("\r\n")

      if exhaustion = exhausted
        key, before = exhaustion
        return PluginResult.new(changed: false, failed: true, msg: "No remaining responses for '#{key}', output was '#{before}'")
      end

      if timed_out
        return PluginResult.new(changed: true, failed: true, msg: "command exceeded timeout", stdout: output, rc: nil)
      end

      rc = status.exit_code? || -1
      if rc == 0
        PluginResult.new(changed: true, failed: false, stdout: output, rc: rc)
      else
        PluginResult.new(changed: true, failed: true, msg: "non-zero return code", stdout: output, rc: rc)
      end
    end

    # Real Ansible's own default (echo: no) means a sent response's text
    # is NOT echoed back into the captured output - turn off the pty's
    # canonical-mode local echo unless the task explicitly asked for it
    # (echo: true), matching pexpect's own `setecho()` behavior.
    private def setup_slave_echo(aslave : LibC::Int, echo : Bool) : Nil
      slave_io = IO::FileDescriptor.new(aslave, blocking: true)
      echo ? slave_io.echo! : slave_io.noecho!
    end

    # Child after fork(): become a session leader and make the pty slave
    # this session's controlling terminal (a plain inherited fd to a tty,
    # with no setsid()/TIOCSCTTY, is never automatically one) - matches
    # what a real interactive shell session looks like to a program
    # checking tcgetpgrp()/expecting job-control signals to work, which
    # `Process.new`'s own spawn (used before this fix) has no hook to
    # arrange between fork and exec. Never returns (always execs or
    # _exits), so the parent's code below never runs in the child.
    #
    # Like pexpect (but unlike a shell), the command string is NOT
    # reinterpreted by /bin/sh - the shlex-split argv execs directly with
    # chdir as the child's cwd.
    private def child_exec(args : Array(String), aslave : LibC::Int, amaster : LibC::Int, chdir : String?) : Nil
      LibC.setsid
      LibC.ioctl(aslave, TIOCSCTTY, 0)
      LibC.dup2(aslave, 0)
      LibC.dup2(aslave, 1)
      LibC.dup2(aslave, 2)
      LibC.close(amaster)
      LibC.close(aslave) if aslave > 2
      LibC.chdir(chdir) if chdir

      argv = Pointer(LibC::Char*).malloc(args.size + 1)
      argv_strs = args.map { |a| a.to_unsafe }
      argv_strs.each_with_index { |ptr, i| argv[i] = ptr }
      argv[args.size] = Pointer(LibC::Char).null
      LibC.execvp(args[0], argv)
      LibC._exit(127) # only reached if execvp itself failed
    end

    # pexpect.spawn's own PATH resolution (pexpect.which semantics: no
    # directories, X_OK access, PATH order).
    private def which(name : String) : String?
      return nil if name.empty?
      return name if name.includes?('/') && File.executable?(name) && !File.directory?(name)

      paths = ENV["PATH"]?.try(&.split(':')) || ["/usr/bin", "/bin"]
      paths.each do |dir|
        candidate = "#{dir}/#{name}"
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end
      nil
    end

    # shlex.split posix mode (what pexpect.spawn applies to the command
    # string): whitespace-separated tokens, single quotes literal,
    # double quotes honoring backslash escapes for \ " ` $ and newline,
    # backslash outside quotes escaping the next character.
    private def shlex_split(s : String) : Array(String)
      tokens = [] of String
      chars = s.chars
      current = IO::Memory.new
      in_token = false
      i = 0

      while i < chars.size
        c = chars[i]
        if c.whitespace?
          if in_token
            tokens << current.to_s
            current.clear
            in_token = false
          end
          i += 1
        elsif c == '\''
          in_token = true
          i += 1
          while i < chars.size && chars[i] != '\''
            current << chars[i]
            i += 1
          end
          i += 1
        elsif c == '"'
          in_token = true
          i += 1
          while i < chars.size && chars[i] != '"'
            if chars[i] == '\\' && i + 1 < chars.size && "\\\"`$".includes?(chars[i + 1])
              current << chars[i + 1]
              i += 2
            else
              current << chars[i]
              i += 1
            end
          end
          i += 1
        elsif c == '\\'
          in_token = true
          if i + 1 < chars.size
            current << chars[i + 1]
            i += 2
          else
            i += 1
          end
        else
          in_token = true
          current << c
          i += 1
        end
      end

      tokens << current.to_s if in_token
      tokens
    end

    # Returns (timed_out, exhausted-pattern-or-nil, output). An exhausted
    # LIST response (the same prompt matching again with no answers left)
    # aborts the loop immediately - real's response_closure fail_json's
    # mid-session the same way.
    private def read_until_deadline(amaster : LibC::Int, responses : Array(Response), deadline : Time::Span) : {Bool, {String, String}?, String}
      buffer = IO::Memory.new
      # Per-pattern (next unsent answer index, search offset) - the
      # search offset advances past each match so a still-visible earlier
      # occurrence in the ever-growing buffer never re-triggers, while a
      # GENUINELY new occurrence of the same prompt (the real-world case
      # a list of responses exists for - the same confirmation prompt
      # appearing once per item) is still found and answered with the
      # next entry in its list.
      search_from = Array.new(responses.size, 0)
      next_answer = Array.new(responses.size, 0)
      chunk = Bytes.new(4096)
      timed_out = false
      exhausted = nil.as({String, String}?)

      loop do
        remaining_ms = (deadline - Time.monotonic).total_milliseconds.to_i
        if remaining_ms <= 0
          timed_out = true
          break
        end

        poll_ret = poll_master(amaster, remaining_ms)

        if poll_ret == 0
          timed_out = true
          break
        elsif poll_ret < 0
          break
        end

        bytes_read = LibC.read(amaster, chunk.to_unsafe, chunk.size).to_i
        break if bytes_read <= 0

        buffer.write(chunk[0, bytes_read])
        exhausted = answer_prompts(amaster, buffer.to_s, responses, search_from, next_answer)
        break if exhausted
      end

      {timed_out, exhausted, buffer.to_s}
    end

    private def poll_master(amaster : LibC::Int, remaining_ms : Int32) : Int32
      pfd = LibC::Pollfd.new
      pfd.fd = amaster
      pfd.events = 1_i16 # POLLIN
      pfd.revents = 0_i16
      LibC.poll(pointerof(pfd), 1_u64, remaining_ms)
    end

    # Per-pattern matching in declaration order; a string response is
    # static (resent on every match), a list response is consumed in
    # order and then EXHAUSTS with real's fail_json wording. Returns the
    # exhausted pattern's (key, text-since-last-match) or nil.
    private def answer_prompts(
      amaster : LibC::Int, text : String,
      responses : Array(Response),
      search_from : Array(Int32), next_answer : Array(Int32),
    ) : {String, String}?
      responses.each_with_index do |(key, pattern, answers, is_list), idx|
        next unless md = pattern.match(text, search_from[idx])

        unless is_list
          payload = (answers[0].rstrip('\n') + "\n").to_slice
          LibC.write(amaster, payload.to_unsafe, payload.size)
          search_from[idx] = md.end(0)
          next
        end

        if next_answer[idx] < answers.size
          payload = (answers[next_answer[idx]].rstrip('\n') + "\n").to_slice
          LibC.write(amaster, payload.to_unsafe, payload.size)
          next_answer[idx] += 1
          search_from[idx] = md.end(0)
        else
          return {key, text[search_from[idx]...md.begin(0)]}
        end
      end

      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ExpectPlugin.new(config)
plugin.run
