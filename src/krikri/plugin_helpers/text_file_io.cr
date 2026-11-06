module Krikri
  module PluginHelpers
    # Ansible's file-editing modules (lineinfile, blockinfile) gained an
    # `encoding` option in 2.21: they open the destination in TEXT mode with
    # that codec instead of reading raw bytes. This is the shared codec
    # layer for those plugins, since Crystal has no transcoder of its own:
    # everything krikri manipulates stays UTF-8, and a non-UTF-8 file is
    # converted at the edges with iconv.
    #
    # The UTF-8 decode failure text is CPython's own (the module raises
    # UnicodeDecodeError, whose message is what the task's msg carries);
    # iconv's messages for the other codecs are not reproduced verbatim.
    module TextFileIO
      UTF8_NAMES = ["utf-8", "utf8", "utf_8", "u8", "utf"]

      def self.utf8?(encoding : String) : Bool
        UTF8_NAMES.includes?(encoding.downcase)
      end

      # Bytes to UTF-8 text: {text, nil}, or {nil, failure message} when the
      # content does not decode.
      def self.decode(bytes : Bytes, encoding : String) : {String?, String?}
        if utf8?(encoding)
          text = String.new(bytes)
          return {text, nil} if text.valid_encoding?
          return {nil, utf8_decode_error(bytes)}
        end

        input = IO::Memory.new(bytes)
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("iconv", ["-f", encoding, "-t", "UTF-8"], input: input, output: output, error: error)
        unless status.success?
          return {nil, iconv_failure(encoding, error.to_s)}
        end
        {output.to_s, nil}
      end

      # UTF-8 text to the file's own encoding: {bytes, nil} or
      # {nil, failure message}.
      def self.encode(text : String, encoding : String) : {Bytes?, String?}
        return {text.to_slice, nil} if utf8?(encoding)

        input = IO::Memory.new(text)
        output = IO::Memory.new
        error = IO::Memory.new
        status = Process.run("iconv", ["-f", "UTF-8", "-t", encoding], input: input, output: output, error: error)
        unless status.success?
          return {nil, iconv_failure(encoding, error.to_s)}
        end
        {output.to_slice, nil}
      end

      # CPython's "'utf-8' codec can't decode byte 0xNN in position N: reason".
      private def self.utf8_decode_error(bytes : Bytes) : String
        position, reason = utf8_failure(bytes)
        byte = bytes[position]
        "'utf-8' codec can't decode byte 0x#{byte.to_s(16, precision: 2)} in position #{position}: #{reason}"
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

      private def self.iconv_failure(encoding : String, stderr : String) : String
        detail = stderr.lines.find { |line| line.includes?("iconv") && !line.includes?("failed") }
        detail = stderr.strip unless detail
        "Unable to convert the file with encoding '#{encoding}': #{detail}"
      end
    end
  end
end
