require "./python_codecs"

module Krikri
  module PluginHelpers
    # Ansible's file-editing modules (lineinfile, blockinfile) gained an
    # `encoding` option in 2.21: they open the destination in TEXT mode with
    # that codec instead of reading raw bytes. This is the shared codec
    # layer for those plugins, since Crystal has no transcoder of its own:
    # everything krikri manipulates stays UTF-8, and a non-UTF-8 file is
    # converted at the edges.
    #
    # Codec names resolve through PythonCodecs (CPython's registry), so an
    # unknown name fails with the module-crash wording real Ansible shows
    # ("Task failed: Module failed: unknown encoding: <name>"), and an
    # undecodable file fails with CPython's UnicodeDecodeError text - the
    # lineinfile/blockinfile open() uses the strict error handler, not
    # replace's surrogateescape.
    module TextFileIO
      # The failure real Ansible produces for a name CPython has no codec
      # for, or nil when the name resolves.
      def self.unknown_codec_failure(encoding : String) : String?
        return nil if PythonCodecs.known?(encoding)
        "Task failed: Module failed: unknown encoding: #{encoding}"
      end

      # Bytes to UTF-8 text: {text, nil}, or {nil, failure message} when the
      # content does not decode.
      def self.decode(bytes : Bytes, encoding : String) : {String?, String?}
        if (failure = unknown_codec_failure(encoding))
          return {nil, failure}
        end

        iconv = PythonCodecs.iconv_name(encoding)
        if iconv.nil? || iconv.in?("utf-8", "ascii")
          text = String.new(bytes)
          return {text, nil} if text.valid_encoding?
          return {nil, utf8_decode_error(bytes)}
        end

        input = IO::Memory.new(bytes)
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("iconv", ["-f", iconv, "-t", "UTF-8"], input: input, output: output, error: error)
        unless status.success?
          return {nil, codec_decode_error(encoding, bytes)}
        end
        {output.to_s, nil}
      end

      # UTF-8 text to the file's own encoding: {bytes, nil} or
      # {nil, failure message}.
      def self.encode(text : String, encoding : String) : {Bytes?, String?}
        if (failure = unknown_codec_failure(encoding))
          return {nil, failure}
        end

        iconv = PythonCodecs.iconv_name(encoding)
        return {text.to_slice, nil} if iconv.nil? || iconv.in?("utf-8", "ascii")

        input = IO::Memory.new(text)
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("iconv", ["-f", "UTF-8", "-t", iconv], input: input, output: output, error: error)
        unless status.success?
          return {nil, codec_encode_error(encoding, text)}
        end
        {output.to_slice, nil}
      end

      # CPython's "'utf-8' codec can't decode byte 0xNN in position N: reason".
      private def self.utf8_decode_error(bytes : Bytes) : String
        position, reason = utf8_failure(bytes)
        "'utf-8' codec can't decode byte 0x#{bytes[position].to_s(16, precision: 2)} in position #{position}: #{reason}"
      end

      # iconv refuses the content: report the first byte that cannot be
      # decoded under this codec, in CPython's wording (its own
      # UnicodeDecodeError names the same byte and offset).
      private def self.codec_decode_error(encoding : String, bytes : Bytes) : String
        position = first_undecodable(bytes, encoding)
        "'#{encoding}' codec can't decode byte 0x#{bytes[position].to_s(16, precision: 2)} in position #{position}: invalid start byte"
      end

      # Character-wise encode failure (a character the target codec cannot
      # represent), reported the way CPython's UnicodeEncodeError is.
      private def self.codec_encode_error(encoding : String, text : String) : String
        position = first_unencodable(text, encoding)
        "'#{encoding}' codec can't encode character '\\u#{text[position].ord.to_s(16, precision: 4)}' in position #{position}: ordinal not in range(256)"
      end

      # Byte offset of the first byte that does not decode on its own under
      # `encoding`, found by converting each leading prefix with iconv.
      private def self.first_undecodable(bytes : Bytes, encoding : String) : Int32
        iconv = PythonCodecs.iconv_name(encoding) || "utf-8"
        index = 0
        while index < bytes.size
          unless iconv_decodes?(bytes[0, index + 1], iconv)
            return index
          end
          index += 1
        end
        0
      end

      # Character offset of the first character `encoding` cannot encode.
      private def self.first_unencodable(text : String, encoding : String) : Int32
        iconv = PythonCodecs.iconv_name(encoding) || "utf-8"
        index = 0
        while index < text.size
          unless iconv_encodes?(text[0, index + 1], iconv)
            return index
          end
          index += 1
        end
        0
      end

      private def self.iconv_decodes?(bytes : Bytes, iconv : String) : Bool
        Process.run("iconv", ["-f", iconv, "-t", "UTF-8"],
          input: IO::Memory.new(bytes), output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      end

      private def self.iconv_encodes?(text : String, iconv : String) : Bool
        Process.run("iconv", ["-f", "UTF-8", "-t", iconv],
          input: IO::Memory.new(text), output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      end

      # First ill-formed position plus CPython's reason string for it.
      private def self.utf8_failure(bytes : Bytes) : {Int32, String}
        index = 0
        while index < bytes.size
          byte = bytes[index]
          if byte < 0x80
            index += 1
            next
          end
          if byte < 0xC2 || byte > 0xF4
            return {index, "invalid start byte"}
          end
          needed, first_low, first_high = if byte < 0xE0
                                            {1, 0x80, 0xBF}
                                          elsif byte < 0xF0
                                            {2, byte == 0xE0 ? 0xA0 : 0x80, 0xBF}
                                          else
                                            {3, byte == 0xF0 ? 0x90 : 0x80, byte == 0xF4 ? 0x8F : 0xBF}
                                          end
          (1..needed).each do |offset|
            return {index, "unexpected end of data"} if index + offset >= bytes.size
            continuation = bytes[index + offset]
            low = offset == 1 ? first_low : 0x80
            high = offset == 1 ? first_high : 0xBF
            return {index + offset, "invalid continuation byte"} unless continuation.in?(low..high)
          end
          index += needed + 1
        end
        {0, "invalid start byte"}
      end
    end
  end
end
