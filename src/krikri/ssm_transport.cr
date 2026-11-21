require "base64"
require "compress/gzip"
require "random/secure"
require "krikri-aws-ssm"
require "./shell"
require "./connection_settings"
require "./ssm_settings"
require "./ssm_registry"
require "./ssm_unreachable_msg"

module Krikri
  # The controller-side SSM transport seam.
  #
  # SSHManager's four entry points (exec, exec_script, upload, download)
  # delegate here whenever ConnectionSettings resolved the dispatch to one
  # of the SSM aliases. The session itself comes from SsmRegistry, keyed
  # by host name + SsmSettings identity; this module drives one serialized
  # shell inside it.
  #
  # One operation at a time per session (SsmRegistry#operation_lock): the
  # marker protocol is not reentrant, so a second command's begin/end
  # markers would otherwise interleave with the first's. The public entry
  # points take the lock; the internal `_locked` helpers assume it and are
  # how upload runs its chmod/rename without deadlocking.
  #
  # Transfers stream base64 in pty-safe 3000-byte lines. Upload probes the
  # target once per session for a decompressor and compresses to a
  # controller temp file (gzip when the target has it, else raw; see
  # #compress_for_upload for why xz is not used locally); download streams
  # the target's `base64` output straight to disk. Every stdin bootstrap waits for a split READY marker
  # before writing bytes, because the pty's canonical buffer is ~4KB and a
  # payload written before the shell reaches `head` would be dropped.
  module SsmTransport
    extend self

    alias Result = NamedTuple(exit_code: Int32, stdout: String, stderr: String)

    DEFAULT_TIMEOUT = 3600
    # Linux MAX_CANON is 4096; keep a conservative margin for the marker
    # and printf scaffolding around the command itself.
    MAX_COMMAND_BYTES = 3500
    # pty canonical input line limit (4096) with margin.
    BASE64_LINE_BYTES = 3000
    # A raw chunk whose base64 is exactly one 3000-byte line. A multiple of
    # 3 means no padding except on the final chunk, so the streamed
    # payload's total size can be computed from the file size alone.
    RAW_CHUNK_BYTES    = 2250
    DECODE_BATCH_BYTES = 4096

    class Error < Exception
    end

    private record Markers, start : String, finish : String,
      ready_first : String, ready_second : String do
      # Printed as two quoted words so an echoed command line can never
      # contain this concatenated marker.
      def ready : String
        ready_first + ready_second
      end
    end

    record TransferCapabilities, decoder : String, gzip : Bool
    record UploadSource, path : String, decoder : String, cleanup : Proc(Nil)

    PROBE_COMMAND = %q{if command -v xz >/dev/null 2>&1; then d=xz; elif command -v gzip >/dev/null 2>&1; then d=gzip; else d=raw; fi; if command -v gzip >/dev/null 2>&1; then g=gzip; else g=no; fi; printf '%s %s\n' "$d" "$g"}

    @@capability_mutex = Mutex.new
    @@capabilities = Hash(UInt64, TransferCapabilities).new

    # --- public operations -------------------------------------------------

    def exec(conn : ConnectionSettings, command : String,
             timeout : Int32 = DEFAULT_TIMEOUT) : Result
      settings = settings_for(conn)
      return windows_result if settings.windows_target?

      session = SsmRegistry.get_or_open(conn.host_name, settings)
      SsmRegistry.operation_lock(session).synchronize do
        SsmRegistry.begin_operation(session)
        begin
          result = exec_locked(conn, session, settings, command, timeout)
          SsmRegistry.end_operation(session, result[:exit_code] != 255)
          result
        rescue ex
          SsmRegistry.end_operation(session, false)
          raise ex
        end
      end
    rescue ex
      failure(ex)
    end

    def exec_script(conn : ConnectionSettings, script : String,
                    timeout : Int32 = DEFAULT_TIMEOUT) : Result
      settings = settings_for(conn)
      return windows_result if settings.windows_target?

      session = SsmRegistry.get_or_open(conn.host_name, settings)
      SsmRegistry.operation_lock(session).synchronize do
        SsmRegistry.begin_operation(session)
        begin
          result = exec_script_locked(session, settings, script, timeout)
          SsmRegistry.end_operation(session, result[:exit_code] != 255)
          result
        rescue ex
          SsmRegistry.end_operation(session, false)
          raise ex
        end
      end
    rescue ex
      failure(ex)
    end

    # Mirrors SSHManager.upload's contract: returns Nil, raises on
    # failure. Directory uploads are left to a later workstream.
    def upload(conn : ConnectionSettings, local_path : String, remote_path : String,
               mode : Int32? = 0o644, recursive : Bool = false) : Nil
      settings = settings_for(conn)
      raise Error.new(settings.windows_unsupported_message) if settings.windows_target?
      validate_upload_source(local_path, recursive)
      perform_upload(conn, settings, local_path, remote_path, mode)
    end

    # Mirrors SSHManager.download's contract: returns Nil, raises on
    # failure. *gzip* asks the target to gzip the stream before base64;
    # the controller then decompresses it locally.
    def download(conn : ConnectionSettings, remote_path : String, local_path : String,
                 timeout : Int32 = DEFAULT_TIMEOUT, gzip : Bool = false) : Nil
      settings = settings_for(conn)
      raise Error.new(settings.windows_unsupported_message) if settings.windows_target?
      perform_download(conn, settings, remote_path, local_path, timeout, gzip)
    end

    # --- op-locked implementations ----------------------------------------

    private def self.exec_locked(conn : ConnectionSettings, session : SsmRegistry::SessionHandle,
                                 settings : SsmSettings, command : String,
                                 timeout : Int32) : Result
      return prep_failure unless prepare_locked(session, settings)
      # A command longer than the pty's canonical line limit is silently
      # truncated by the line discipline. Run it through the stdin-fed
      # bootstrap instead.
      return exec_script_locked(session, settings, command, timeout) if command.bytesize > MAX_COMMAND_BYTES

      markers = new_markers
      line = String.build do |io|
        io << "printf '\\n%s\\n' " << Shell.quote_arg(markers.start)
        io << "; /bin/bash -c " << Shell.quote_arg(command)
        io << "; printf '\\n%s\\n%s\\n' \"$?\" " << Shell.quote_arg(markers.finish)
      end
      # Quote every command byte, not the raw command: a shell-quoted single
      # quote expands to three bytes, so a short command full of quotes can
      # still overflow MAX_CANON and truncate the end marker.
      return exec_script_locked(session, settings, command, timeout) if line.bytesize > MAX_COMMAND_BYTES

      session.write(line + "\n")
      collect(session, markers, timeout)
    end

    private def self.exec_script_locked(session : SsmRegistry::SessionHandle,
                                        settings : SsmSettings, script : String,
                                        timeout : Int32) : Result
      return prep_failure unless prepare_locked(session, settings)

      payload = Base64.strict_encode(script)
      markers = new_markers
      line = String.build do |io|
        io << "printf '\\n%s\\n' " << Shell.quote_arg(markers.start)
        # READY comes from inside the consumer: on a live agent, printing it
        # before the pipeline starts let the first ~200 KiB be written before
        # `head` was reading, and the agent dropped it.
        io << "; ( printf '%s%s\\n' " << Shell.quote_arg(markers.ready_first) << ' '
        io << Shell.quote_arg(markers.ready_second) << " >&2; exec head -c "
        io << wrapped_encoded_size(payload.bytesize.to_i64) << " ) | base64 -d | bash"
        io << "; printf '\\n%s\\n%s\\n' \"$?\" " << Shell.quote_arg(markers.finish)
      end
      session.write(line + "\n")
      return bootstrap_failure unless wait_for_marker(session, markers.ready, timeout)
      sleep 50.milliseconds
      write_payload(session, payload, timeout)
      collect_after_ready(session, markers.finish, timeout)
    end

    private def self.perform_upload(conn : ConnectionSettings, settings : SsmSettings,
                                    local_path : String, remote_path : String,
                                    mode : Int32?) : Nil
      session = SsmRegistry.get_or_open(conn.host_name, settings)
      SsmRegistry.operation_lock(session).synchronize do
        SsmRegistry.begin_operation(session)
        begin
          raise Error.new(prep_failure[:stderr]) unless prepare_locked(session, settings)
          capabilities = capabilities_locked(conn, session, settings, DEFAULT_TIMEOUT)
          source = compress_for_upload(local_path, capabilities)
          begin
            result = stream_upload_locked(session, source, remote_path, mode)
            unless result[:exit_code] == 0
              detail = result[:stderr].strip
              detail = "no output" if detail.empty?
              raise Error.new("Failed to upload #{local_path} to #{settings.target}:#{remote_path}: #{detail}")
            end
          ensure
            source.cleanup.call
          end
          SsmRegistry.end_operation(session, true)
        rescue ex
          SsmRegistry.end_operation(session, false)
          raise ex
        end
      end
    rescue ex : KrikriAwsSsm::Error
      raise Error.new(SsmUnreachableMsg.unreachable_text(ex))
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new("Failed to upload #{local_path} to #{remote_path}: #{ex.message}")
    end

    private def self.perform_download(conn : ConnectionSettings, settings : SsmSettings,
                                      remote_path : String, local_path : String,
                                      timeout : Int32, gzip : Bool) : Nil
      session = SsmRegistry.get_or_open(conn.host_name, settings)
      SsmRegistry.operation_lock(session).synchronize do
        SsmRegistry.begin_operation(session)
        begin
          raise Error.new(prep_failure[:stderr]) unless prepare_locked(session, settings)
          capabilities = gzip ? capabilities_locked(conn, session, settings, timeout) : nil
          if gzip && !capabilities.try(&.gzip)
            raise Error.new("#{SsmUnreachableMsg::PREFIX}target has no gzip for a compressed download")
          end
          download_locked(session, remote_path, local_path, timeout, gzip)
          SsmRegistry.end_operation(session, true)
        rescue ex
          SsmRegistry.end_operation(session, false)
          raise ex
        end
      end
    rescue ex : KrikriAwsSsm::Error
      raise Error.new(SsmUnreachableMsg.unreachable_text(ex))
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new("Failed to download #{remote_path} to #{local_path}: #{ex.message}")
    end

    private def self.download_locked(session : SsmRegistry::SessionHandle,
                                     remote_path : String, local_path : String,
                                     timeout : Int32, gzip : Bool) : Nil
      markers = new_markers
      source = gzip ? "gzip -c < #{Shell.quote_arg(remote_path)} | base64" : "base64 < #{Shell.quote_arg(remote_path)}"
      line = String.build do |io|
        io << "printf '\\n%s\\n' " << Shell.quote_arg(markers.start)
        io << "; " << source
        io << "; printf '\\n%s\\n%s\\n' " << Shell.quote_arg(markers.finish) << " \"$?\""
      end
      session.write(line + "\n")

      final_tmp = local_temp_path(local_path)
      raw_tmp = local_temp_path(local_path, ".gz")
      begin
        if gzip
          File.open(raw_tmp, "wb") do |sink|
            result = receive_base64_stream(session, markers, timeout, sink)
            raise Error.new(download_failure_text(result, remote_path, local_path)) unless result[:exit_code] == 0
          end
          File.open(raw_tmp, "rb") do |input|
            Compress::Gzip::Reader.open(input) do |reader|
              File.open(final_tmp, "wb") { |output| IO.copy(reader, output) }
            end
          end
        else
          File.open(final_tmp, "wb") do |sink|
            result = receive_base64_stream(session, markers, timeout, sink)
            raise Error.new(download_failure_text(result, remote_path, local_path)) unless result[:exit_code] == 0
          end
        end
        File.rename(final_tmp, local_path)
      ensure
        File.delete(raw_tmp) if File.exists?(raw_tmp)
        File.delete(final_tmp) if File.exists?(final_tmp)
      end
    end

    private def self.download_failure_text(result : Result, remote_path : String,
                                           local_path : String) : String
      detail = result[:stderr].strip
      detail = "no output" if detail.empty?
      "Failed to download #{remote_path} to #{local_path}: #{detail}"
    end

    private def self.stream_upload_locked(session : SsmRegistry::SessionHandle,
                                          source : UploadSource, remote_path : String,
                                          mode : Int32?) : Result
      size = File.size(source.path).to_i64
      payload_size = wrapped_base64_size(size)
      remote_tmp = remote_temp_path(remote_path)
      q_tmp = Shell.quote_arg(remote_tmp)
      q_dest = Shell.quote_arg(remote_path)
      decoder = case source.decoder
                when "xz"   then "xz -dc"
                when "gzip" then "gzip -dc"
                else             "cat"
                end
      chmod = mode && mode != 0o644 ? "chmod #{mode.to_s(8)} #{q_tmp} && " : ""
      markers = new_markers
      line = String.build do |io|
        io << "printf '\\n%s\\n' " << Shell.quote_arg(markers.start)
        io << "; rm -f " << q_tmp << " 2>/dev/null"
        # READY is printed by the consumer itself, so streaming only starts
        # once `head` is reading; see exec_script_locked for the live reason.
        io << "; ( printf '%s%s\\n' " << Shell.quote_arg(markers.ready_first) << ' '
        io << Shell.quote_arg(markers.ready_second) << " >&2; exec head -c " << payload_size
        io << " ) | base64 -d | " << decoder << " > " << q_tmp
        io << " && " << chmod << "mv -f " << q_tmp << ' ' << q_dest
        io << "; rc=$?"
        io << "; [ $rc -eq 0 ] || rm -f " << q_tmp << " 2>/dev/null"
        io << "; printf '\\n%s\\n%s\\n' \"$rc\" " << Shell.quote_arg(markers.finish)
      end
      session.write(line + "\n")
      return bootstrap_failure unless wait_for_marker(session, markers.ready, DEFAULT_TIMEOUT)
      sleep 50.milliseconds
      write_stream_payload(session, source.path, DEFAULT_TIMEOUT)
      collect_after_ready(session, markers.finish, DEFAULT_TIMEOUT)
    end

    # --- shared shell helpers ---------------------------------------------

    private def self.prepare_locked(session : SsmRegistry::SessionHandle,
                                    settings : SsmSettings) : Bool
      return true if SsmRegistry.prepared?(session)

      marker = "KRIKRI-SSM-#{Random::Secure.hex(10)}"
      first = "#{marker}-"
      second = "KRIKRI"
      line = String.build do |io|
        io << "stty -echo 2>/dev/null; unset PROMPT_COMMAND; PS1=''; export TERM=dumb; "
        io << "stty -onlcr 2>/dev/null; "
        io << "printf '%s%s\\n' " << Shell.quote_arg(first) << ' ' << Shell.quote_arg(second)
      end
      session.write(line + "\n")
      return false unless wait_for_marker(session, first + second, settings.timeout)

      SsmRegistry.mark_prepared(session)
      true
    end

    private def self.capabilities_locked(conn : ConnectionSettings,
                                         session : SsmRegistry::SessionHandle,
                                         settings : SsmSettings,
                                         timeout : Int32) : TransferCapabilities
      @@capability_mutex.synchronize do
        if cached = @@capabilities[session.object_id]?
          return cached
        end
      end

      result = exec_locked(conn, session, settings, PROBE_COMMAND, timeout)
      capabilities = parse_capabilities(result)
      @@capability_mutex.synchronize { @@capabilities[session.object_id] = capabilities }
      capabilities
    end

    private def self.parse_capabilities(result : Result) : TransferCapabilities
      return TransferCapabilities.new("raw", false) unless result[:exit_code] == 0
      parts = result[:stdout].strip.split(/\s+/)
      decoder = parts[0]? || "raw"
      decoder = "raw" unless {"xz", "gzip", "raw"}.includes?(decoder)
      gzip = parts[1]? == "gzip"
      TransferCapabilities.new(decoder, gzip)
    end

    private def self.wait_for_marker(session : SsmRegistry::SessionHandle, marker : String,
                                     timeout : Int32) : Bool
      done = Channel(Bool).new(1)
      buffer = ""
      spawn do
        found = false
        while output = session.read?
          next unless output.stream == KrikriAwsSsm::Stream::Stdout
          buffer += String.new(output.bytes)
          if buffer.includes?(marker)
            found = true
            break
          end
        end
        done.send(found)
      end
      select
      when found = done.receive
        found
      when timeout(timeout.seconds)
        session.terminate
        false
      end
    end

    private def self.collect(session : SsmRegistry::SessionHandle, markers : Markers,
                             timeout : Int32) : Result
      done = Channel(Result?).new(1)
      spawn do
        raw_stdout = ""
        raw_stderr = ""
        result = nil
        while output = session.read?
          text = String.new(output.bytes)
          if output.stream == KrikriAwsSsm::Stream::Stderr
            raw_stderr += text
            next
          end

          raw_stdout += text
          if raw_stdout.includes?(markers.finish)
            result = parse_exec_output(raw_stdout, raw_stderr, markers.start, markers.finish) ||
                     Result.new(exit_code: 255, stdout: "", stderr: "#{SsmUnreachableMsg::PREFIX}command result did not contain an exit code")
            break
          end
        end
        done.send(result)
      end

      select
      when result = done.receive
        result || closed_result(session)
      when timeout(timeout.seconds)
        session.terminate
        Result.new(exit_code: 255, stdout: "", stderr: "#{SsmUnreachableMsg::PREFIX}command timed out after #{timeout} second(s)")
      end
    end

    # The READY-wait consumes the bootstrap's START/READY output, so the
    # body collector that follows has no start marker to seek: it starts
    # at the first command byte and only looks for the end marker.
    private def self.collect_after_ready(session : SsmRegistry::SessionHandle,
                                         end_marker : String, timeout : Int32) : Result
      done = Channel(Result?).new(1)
      raw_stdout = ""
      raw_stderr = ""
      spawn do
        result = nil
        while output = session.read?
          text = String.new(output.bytes)
          if output.stream == KrikriAwsSsm::Stream::Stderr
            raw_stderr += text
            next
          end

          raw_stdout += text
          if raw_stdout.includes?(end_marker)
            result = parse_tail(raw_stdout, raw_stderr, end_marker) ||
                     Result.new(exit_code: 255, stdout: "", stderr: "#{SsmUnreachableMsg::PREFIX}command result did not contain an exit code")
            break
          end
        end
        done.send(result)
      end

      select
      when result = done.receive
        result || closed_result(session)
      when timeout(timeout.seconds)
        session.terminate
        Result.new(exit_code: 255, stdout: "", stderr: "#{SsmUnreachableMsg::PREFIX}command timed out after #{timeout} second(s)")
      end
    end

    private def self.parse_tail(raw_stdout : String, raw_stderr : String,
                                end_marker : String) : Result?
      out = raw_stdout.gsub('\r', "")
      finish_at = out.index(end_marker)
      return nil unless finish_at
      body = out[0...finish_at]
      if match = body.match(/\n(\d+)\n\z/)
        Result.new(exit_code: match[1].to_i, stdout: body[0, match.begin(0)],
          stderr: raw_stderr.gsub('\r', ""))
      end
    end

    # Stream a `base64`-producing command's output into *sink* without
    # holding the whole encoded payload in memory. The command must print
    # START, then base64 data, then END followed by the exit code:
    #   printf '\n%s\n' START; base64 < src; printf '\n%s\n%s\n' END "$?"
    # Returns the command's exit code (or a 255 transport result).
    private def self.receive_base64_stream(session : SsmRegistry::SessionHandle,
                                           markers : Markers, timeout : Int32,
                                           sink : IO) : Result
      done = Channel(Result?).new(1)
      spawn do
        raw_stderr = ""
        reader = TransferStreamReader.new(markers) { |bytes| sink.write(bytes) }
        result = nil
        while output = session.read?
          text = String.new(output.bytes).gsub('\r', "")
          if output.stream == KrikriAwsSsm::Stream::Stderr
            raw_stderr += text
            next
          end

          if code = reader.feed(text)
            result = Result.new(exit_code: code.to_i, stdout: "", stderr: raw_stderr)
            break
          end
        end
        done.send(result)
      end

      select
      when result = done.receive
        result || closed_result(session)
      when timeout(timeout.seconds)
        session.terminate
        Result.new(exit_code: 255, stdout: "", stderr: "#{SsmUnreachableMsg::PREFIX}transfer timed out after #{timeout} second(s)")
      end
    end

    # The state machine for a streamed download: discard until START,
    # decode until END, then read the `\n<code>\n` tail. Split from the
    # session loop so each stage stays small and testable.
    private class TransferStreamReader
      def initialize(@markers : Markers, &@sink : Bytes -> Nil)
        @pending = ""
        @tail = ""
        @stage = 0
        @decoder = Base64StreamDecoder.new { |bytes| @sink.call(bytes) }
      end

      # Returns the exit-code text once the end marker and its trailing
      # exit line are complete, else nil.
      def feed(text : String) : String?
        unless @stage == 2
          @pending += text
          return nil if @stage == 0 && !consume_start
          return nil unless consume_body
        else
          @tail += text
        end

        if match = @tail.match(/\A\n(\d+)\n/)
          @decoder.finish
          match[1]
        end
      end

      private def consume_start : Bool
        if index = @pending.index(@markers.start)
          @stage = 1
          @pending = @pending[(index + @markers.start.size)..]
          true
        else
          keep = @markers.start.size - 1
          @pending = @pending[-(keep)..] if @pending.size > keep
          false
        end
      end

      private def consume_body : Bool
        if index = @pending.index(@markers.finish)
          @decoder.feed(@pending[0, index])
          @tail = @pending[(index + @markers.finish.size)..]
          @pending = ""
          @stage = 2
          true
        else
          keep = @markers.finish.size - 1
          if @pending.size > keep
            @decoder.feed(@pending[0, @pending.size - keep])
            @pending = @pending[(@pending.size - keep)..]
          end
          false
        end
      end
    end

    # Stream a base64 string in pty-safe 3000-byte lines. A single large
    # write can lose bytes to the pty's canonical buffer/read-ahead, so
    # scripts use the same line-at-a-time path as transfers.
    private def self.write_payload(session : SsmRegistry::SessionHandle, payload : String,
                                   timeout : Int32) : Nil
      done = Channel(Exception?).new(1)
      spawn do
        offset = 0
        while offset < payload.bytesize
          length = Math.min(BASE64_LINE_BYTES, payload.bytesize - offset)
          session.write(payload[offset, length] + "\n")
          offset += length
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      select
      when error = done.receive
        raise error if error
      when timeout(timeout.seconds)
        session.terminate
        raise Error.new("#{SsmUnreachableMsg::PREFIX}transfer timed out after #{timeout} second(s)")
      end
    end

    # Read the compressed source in exact 2250-byte chunks (base64 3000
    # bytes each), so `head -c N` sees exactly the bytes
    # wrapped_base64_size computed.
    private def self.write_stream_payload(session : SsmRegistry::SessionHandle,
                                          path : String, timeout : Int32) : Nil
      done = Channel(Exception?).new(1)
      spawn do
        File.open(path, "rb") do |input|
          buffer = Bytes.new(RAW_CHUNK_BYTES)
          while (count = input.read_greedy(buffer)) > 0
            session.write(Base64.strict_encode(buffer[0, count]) + "\n")
          end
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
      select
      when error = done.receive
        raise error if error
      when timeout(timeout.seconds)
        session.terminate
        raise Error.new("#{SsmUnreachableMsg::PREFIX}transfer timed out after #{timeout} second(s)")
      end
    end

    # Total bytes written by write_stream_payload for a *size*-byte source:
    # base64 length (4 chars per 3 bytes) plus one newline per 3000-byte
    # line. RAW_CHUNK_BYTES is a multiple of 3, so chunk padding never
    # changes this total.
    def self.wrapped_base64_size(size : Int64) : Int64
      wrapped_encoded_size(4_i64 * ((size + 2_i64) // 3_i64))
    end

    # Newline-wrapped size of an already-base64-encoded stream (used by
    # the script bootstrap, whose payload is encoded in memory).
    def self.wrapped_encoded_size(encoded : Int64) : Int64
      return 0_i64 if encoded == 0
      line = BASE64_LINE_BYTES.to_i64
      encoded + (encoded + line - 1_i64) // line
    end

    # --- compression -------------------------------------------------------

    # gzip, never a local xz. The pinned xz shard (naqvis/xz.cr) truncates
    # multi-megabyte streams: its Writer#close can stop before the stream
    # footer is emitted, so the target's `xz -dc` exits 1 after writing the
    # full payload and the upload fails. That is exactly the 42 MB fat
    # plugin binary krikri uploads per host. gzip's stdlib writer is
    # verified end-to-end and, at this size, also faster on the controller
    # (~1.5 s and 13 MB vs ~30 s and 7 MB), so the size win does not pay
    # for the transfer it saves. The target-side `xz` probe stays because
    # an xz-only image still needs the raw fallback, and the capability is
    # recorded per session.
    #
    # Public as a spec seam.
    def self.compress_for_upload(local_path : String,
                                 capabilities : TransferCapabilities) : UploadSource
      if capabilities.gzip
        begin
          return compress_with(local_path, "gzip", ".gz")
        rescue
          # local gzip unavailable/failed - fall back to the raw payload
        end
      end
      UploadSource.new(local_path, "raw", -> { nil })
    end

    private def self.compress_with(local_path : String, kind : String, suffix : String) : UploadSource
      path = File.tempname("krikri-ssm-upload", suffix)
      File.open(local_path, "rb") do |input|
        File.open(path, "wb") do |output|
          Compress::Gzip::Writer.open(output) { |writer| IO.copy(input, writer) }
        end
      end
      UploadSource.new(path, kind, -> { File.delete(path) if File.exists?(path); nil })
    end

    # --- markers / parsing -------------------------------------------------

    # Pure marker parser, exposed for specs: strips CRs, discards the
    # banner before the start marker, splits stderr, and lifts the exit
    # code off the `\n<code>\n<end>` tail. nil when the markers are not
    # both present.
    def parse_exec_output(raw_stdout : String, raw_stderr : String,
                          start_marker : String, end_marker : String) : Result?
      out = raw_stdout.gsub('\r', "")
      err = raw_stderr.gsub('\r', "")
      start_at = out.index(start_marker)
      return nil unless start_at
      finish_at = out.index(end_marker, start_at + start_marker.size)
      return nil unless finish_at

      body = out[(start_at + start_marker.size)...finish_at]
      body = body[1..] if body.starts_with?('\n')
      if match = body.match(/\n(\d+)\n\z/)
        Result.new(exit_code: match[1].to_i, stdout: body[0, match.begin(0)], stderr: err)
      end
    end

    private def self.new_markers : Markers
      seed = Random::Secure.hex(12)
      Markers.new(
        start: "KRIKRI-SSM-BEGIN-#{seed}",
        finish: "KRIKRI-SSM-END-#{seed}",
        ready_first: "KRIKRI-SSM-READY-#{seed}-",
        ready_second: "READY"
      )
    end

    # --- paths -------------------------------------------------------------

    private def self.remote_temp_path(remote_path : String) : String
      File.join(File.dirname(remote_path), ".krikri-upload-#{Random::Secure.hex(8)}")
    end

    private def self.local_temp_path(local_path : String, suffix : String = "") : String
      File.join(File.dirname(local_path), ".krikri-download-#{Random::Secure.hex(8)}#{suffix}")
    end

    # --- results -----------------------------------------------------------

    private def self.closed_result(session : SsmRegistry::SessionHandle) : Result
      Result.new(exit_code: 255, stdout: "",
        stderr: SsmUnreachableMsg.for_close(session.close_reason, session.error))
    end

    private def self.prep_failure : Result
      Result.new(exit_code: 255, stdout: "",
        stderr: "#{SsmUnreachableMsg::PREFIX}transport could not prepare the session shell")
    end

    private def self.bootstrap_failure : Result
      Result.new(exit_code: 255, stdout: "",
        stderr: "#{SsmUnreachableMsg::PREFIX}transport could not start the stdin bootstrap")
    end

    private def self.windows_result : Result
      Result.new(exit_code: 255, stdout: "", stderr: SsmUnreachableMsg::WINDOWS_UNSUPPORTED)
    end

    private def self.failure(ex : Exception) : Result
      Result.new(exit_code: 255, stdout: "", stderr: SsmUnreachableMsg.unreachable_text(ex))
    end

    # --- settings / factory ------------------------------------------------

    private def self.settings_for(conn : ConnectionSettings) : SsmSettings
      conn.ssm || raise Error.new("SSM transport requested for a non-SSM connection")
    end

    private def self.validate_upload_source(local_path : String, recursive : Bool) : Nil
      if recursive && Dir.exists?(local_path)
        raise Error.new("SSM upload of directories is not implemented yet: #{local_path}")
      end
      raise "Local file not found: #{local_path}" unless File.exists?(local_path)
    end

    # Builds the KrikriAwsSsm::Settings for one resolved SsmSettings.
    def shard_settings(settings : SsmSettings) : KrikriAwsSsm::Settings
      credentials = settings.static_credentials
      KrikriAwsSsm::Settings.new(
        target: settings.target,
        region: settings.region,
        profile: settings.profile,
        endpoint_url: settings.endpoint_url,
        allow_insecure_endpoint: settings.insecure_endpoint?,
        document: settings.document,
        connect_timeout: settings.timeout.seconds,
        read_timeout: settings.timeout.seconds,
        retries: settings.retries,
        credentials: credentials.try { |creds| KrikriAwsSsm::Credentials.new(creds[:access_key], creds[:secret_key], creds[:session_token]) }
      )
    end

    # The shard-backed default session factory, installed here so
    # ssm_registry.cr stays usable with an injected factory in specs.
    def open_session(settings : SsmSettings) : SsmRegistry::SessionHandle
      KrikriAwsSsm::Session.open(shard_settings(settings))
    end

    # Incremental base64 decoder for a streamed download. Whitespace and
    # CR/LF are dropped; complete batches are decoded and handed to the
    # sink, so a 40MB download never holds its encoded form in memory.
    private class Base64StreamDecoder
      def initialize(&@sink : Bytes -> Nil)
        @buffer = ""
      end

      def feed(text : String) : Nil
        clean = text.gsub(/[^A-Za-z0-9+\/=]/, "")
        return if clean.empty?
        @buffer += clean
        drain(final: false)
      end

      def finish : Nil
        drain(final: true)
      end

      private def drain(final : Bool) : Nil
        loop do
          available = @buffer.size
          break if available == 0
          take = final ? available : (available // DECODE_BATCH_BYTES) * DECODE_BATCH_BYTES
          break if take == 0
          chunk = @buffer[0, take]
          @buffer = @buffer[take..]
          @sink.call(Base64.decode(chunk))
        end
      end
    end
  end
end

Krikri::SsmRegistry.default_factory =
  ->(settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
    Krikri::SsmTransport.open_session(settings)
  }
