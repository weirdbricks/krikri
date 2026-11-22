require "process"

module Krikri
  # The target-side half of the SSM rsync pipe (see SsmRsyncRsh).
  #
  # It runs as the session's command, so its own stdin/stdout are the pty.
  # rsync's server cannot talk its binary protocol through a terminal (a
  # raw-mode pty still stalls it after the startup exchange), but it can
  # through pipes: this bridge spawns the command with real pipes and pumps
  # both directions unchanged. The exit status is the child's, so the agent's
  # ExitCode carries it back.
  #
  # Deliberate limit: the child's stderr is discarded. It shares the pty with
  # the protocol, so forwarding it would corrupt the stream; rsync sends its
  # transfer errors over the protocol itself, which is what the client prints.
  module SsmPipeBridge
    extend self

    PUMP_CHUNK_BYTES = 64 * 1024

    def run(argv : Array(String), input : IO = STDIN, output : IO = STDOUT) : Int32
      # Runner-script probe: catches exec-format/loader failures BEFORE the
      # start marker, while a diagnostic can still be shown to the client.
      return 0 if argv == ["--probe"]
      if argv.empty?
        STDERR.puts "krikri-ssm-pipe: no command given"
        return 64
      end

      dev_null = File.open(File::NULL, "w")
      process = Process.new(argv[0], argv[1..],
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: dev_null)
      dev_null.close

      # The client never signals end of input (raw mode has no VEOF), so this
      # fiber may still be blocked when the child exits; the process exit
      # below takes it down with everything else.
      spawn do
        buffer = Bytes.new(PUMP_CHUNK_BYTES)
        begin
          while (count = input.read(buffer)) > 0
            process.input.write(buffer[0, count])
            process.input.flush
          end
          process.input.close
        rescue IO::Error
          # The child exited first; its status is the result.
        end
      end

      # Flush per chunk: Crystal buffers STDOUT when it is a pipe, and the
      # client is waiting on every byte of the protocol.
      buffer = Bytes.new(PUMP_CHUNK_BYTES)
      begin
        while (count = process.output.read(buffer)) > 0
          output.write(buffer[0, count])
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
  end
end
