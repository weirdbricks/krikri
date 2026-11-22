require "process"
require "./ssm_pipe_frame"

module Krikri
  # The target-side half of the SSM rsync pipe (see SsmRsyncRsh).
  #
  # It runs as the session's command, so its own stdin/stdout are the pty.
  # rsync's server cannot talk its binary protocol through a terminal (a
  # raw-mode pty still stalls it after the startup exchange), but it can
  # through pipes: this bridge spawns the command with real pipes and pumps
  # both directions unchanged. The exit status is the child's; the runner's
  # EXIT trap records it in the status file, because the agent delivers no
  # ExitCode payload for every session (verified against a real agent).
  #
  # Output goes out as padded length-prefixed frames (SsmPipeFrame): the
  # agent's output path holds back a small chunk tail that starts with a
  # high byte and loses it at end of stream, which would eat rsync's
  # handshake messages. The helper strips the frame and pad again.
  #
  # The child's stderr goes to the file the runner names
  # (KRIKRI_SSM_PIPE_STDERR), not the pty: sharing the pty would corrupt the
  # protocol, but discarding it entirely loses the only diagnostic a
  # pre-protocol failure has. rsync's transfer errors travel over the
  # protocol itself and reach the client either way.
  module SsmPipeBridge
    extend self

    PUMP_CHUNK_BYTES = 64 * 1024

    def run(argv : Array(String), input : IO = STDIN, output : IO = STDOUT) : Int32
      # Runner-script probe: catches exec-format/loader failures BEFORE the
      # start marker, while a diagnostic can still be shown to the client.
      return 0 if argv == ["--probe"]

      # The runner may hand us a file for the command's stderr: sharing the
      # pty would corrupt the protocol, but discarding it entirely loses the
      # only diagnostic a pre-protocol failure has. The file is 0600: it can
      # hold remote command errors with file names in them.
      error_io = if path = ENV["KRIKRI_SSM_PIPE_STDERR"]?
                   File.open(path, "w", perm: 0o600)
                 else
                   File.open(File::NULL, "w")
                 end
      if argv.empty?
        error_io.puts "krikri-ssm-pipe: no command given"
        error_io.close
        return 64
      end

      # A spawn failure (no rsync on the target, exec-format error, ...) must
      # reach the stderr file too: the runner sends this bridge's own stderr
      # to /dev/null, so without this rescue the caller sees only an empty
      # file and an unexplained error.
      begin
        process = Process.new(argv[0], argv[1..],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: error_io)
      rescue ex : File::NotFoundError
        error_io.puts "krikri-ssm-pipe: cannot run #{argv[0]}: #{ex.message}"
        error_io.close
        return 127
      rescue ex : IO::Error
        error_io.puts "krikri-ssm-pipe: cannot run #{argv[0]}: #{ex.message}"
        error_io.close
        return 126
      end
      error_io.close

      # Input arrives framed: a 4-byte big-endian length followed by that many
      # bytes, and a zero length means end of input. A pty has no EOF to send
      # (raw mode has no VEOF), and rsync's server waits for its stdin to
      # close before it exits - without this frame the pull stalls. The child
      # gets its stdin closed on the zero-length frame.
      spawn { pump_framed_input(input, process) }

      # One padded frame per chunk, written and flushed together (see
      # SsmPipeFrame for why the pad matters).
      buffer = Bytes.new(PUMP_CHUNK_BYTES)
      begin
        while (count = process.output.read(buffer)) > 0
          output.write(SsmPipeFrame.encode(buffer[0, count]))
          output.flush
        end
      rescue IO::Error
      end
      status = process.wait
      # ssh semantics: 128 + signal number for a signaled child, so rsync and
      # the task see a conventional status instead of a flat 128.
      if code = status.exit_code?
        code
      elsif signal = status.exit_signal?
        128 + signal.value
      else
        128
      end
    end

    private def pump_framed_input(input : IO, process : Process) : Nil
      header = Bytes.new(4)
      begin
        loop do
          input.read_fully(header)
          length = IO::ByteFormat::BigEndian.decode(UInt32, header)
          if length == 0
            process.input.close
            break
          end
          if length > SsmPipeFrame::MAX_PAYLOAD
            # Corrupt or foreign framing: refuse the allocation (the
            # length is a full UInt32) and end the input so the child
            # fails fast instead of blocking on a payload that never
            # arrives.
            process.input.close
            break
          end
          payload = Bytes.new(length)
          input.read_fully(payload)
          process.input.write(payload)
          process.input.flush
        end
      rescue IO::Error | IO::EOFError
        # The child or the session went away; its status is the result.
      end
    end
  end
end
