module Krikri
  # Python's errors="surrogateescape" byte<->text mapping, for the places
  # that read a UTF-8 file the way Ansible's DataLoader does: a strict
  # decode first, then - on failure - a lossless one, with each byte that
  # is not part of a valid UTF-8 sequence surviving the trip through the
  # template engine unchanged.
  #
  # Python maps such a byte to one of U+DC80..U+DCFF. Crystal strings
  # cannot hold lone surrogates (they are not UTF-8) and PCRE2 refuses a
  # subject containing one, so the twin used here is the private-use
  # codepoint U+F780+(byte-0x80), exactly the mapping plugins/replace.cr
  # already uses for the same reason: one undecodable byte is one
  # character to the engine either way, and encode() restores the exact
  # original bytes on write.
  module SurrogateEscape
    extend self

    TWIN_BASE = 0xF780

    def decode(bytes : Bytes) : String
      String.build do |buffer|
        i = 0
        size = bytes.size
        while i < size
          if len = utf8_sequence_length(bytes[i])
            if i + len <= size && valid_continuation?(bytes, i, len)
              buffer.write(bytes[i, len])
              i += len
              next
            end
          end
          buffer << (TWIN_BASE + bytes[i] - 0x80).chr
          i += 1
        end
      end
    end

    def encode(content : String) : Bytes
      output = Bytes.new(content.bytesize)
      w = 0
      content.each_char do |char|
        codepoint = char.ord
        if codepoint >= TWIN_BASE && codepoint <= TWIN_BASE + 0x7F
          output[w] = (0x80 + codepoint - TWIN_BASE).to_u8
          w += 1
        else
          char.bytes.each do |byte|
            output[w] = byte
            w += 1
          end
        end
      end
      output[0, w]
    end

    # Length of the complete, valid UTF-8 sequence starting at *index*,
    # or nil when that byte starts none (or the sequence is truncated).
    # Bounds-checked, unlike a Char::Reader walk, which reads past the
    # end of a truncated tail sequence - the byte-at-a-time resync here
    # is what lets a caller reproduce CPython's `errors="replace"` output
    # for such a string.
    def self.valid_sequence_length(bytes : Bytes, index : Int32) : Int32?
      return nil unless lead = utf8_sequence_length(bytes[index])
      return lead if index + lead <= bytes.size && valid_continuation?(bytes, index, lead)
      nil
    end

    # Bytes in the UTF-8 sequence this lead byte starts, or nil when it
    # cannot start one. Strict UTF-8, exactly as CPython's decoder
    # validates: no overlong forms, no surrogates, max U+10FFFF - a
    # rejected byte is escaped individually (CPython resyncs one byte at
    # a time, so an overlong sequence becomes one twin per byte).
    private def utf8_sequence_length(lead : UInt8) : Int32?
      if lead <= 0x7F
        1
      elsif lead >= 0xC2 && lead <= 0xDF
        2
      elsif lead >= 0xE0 && lead <= 0xEF
        3
      elsif lead >= 0xF0 && lead <= 0xF4
        4
      end
    end

    private def valid_continuation?(bytes : Bytes, start : Int32, len : Int32) : Bool
      return true if len == 1
      b1 = bytes[start + 1]
      b2 = bytes[start + 2]?
      case len
      when 2
        b1.in?(0x80..0xBF)
      when 3
        second_ok = case bytes[start]
                    when 0xE0 then b1.in?(0xA0..0xBF)
                    when 0xED then b1.in?(0x80..0x9F)
                    else           b1.in?(0x80..0xBF)
                    end
        second_ok && !!b2.try(&.in?(0x80..0xBF))
      else
        second_ok = case bytes[start]
                    when 0xF0 then b1.in?(0x90..0xBF)
                    when 0xF4 then b1.in?(0x80..0x8F)
                    else           b1.in?(0x80..0xBF)
                    end
        second_ok && !!b2.try(&.in?(0x80..0xBF)) &&
          !!bytes[start + 3]?.try(&.in?(0x80..0xBF))
      end
    end
  end
end
