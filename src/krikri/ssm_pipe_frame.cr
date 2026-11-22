module Krikri
  # Length-prefixed framing for the SSM rsync pipe's output half (see
  # SsmPipeBridge and SsmTransport.pipe).
  #
  # The real agent's output path holds back the tail of a chunk when the tail
  # starts with a high byte (>= 0x80) and is at most three bytes long, and
  # prepends it to the next chunk; at end of stream those bytes are lost, and
  # interactively they deadlock the protocol (rsync's handshake messages are
  # exactly the vulnerable size). Verified against a real agent: the
  # four-byte message `38 bf 09 6b` arrived as the single byte `38`, and a
  # held `bf 42` reappeared prefixed to the next write two seconds later.
  #
  # Every chunk therefore goes out as one frame, written with a single
  # write+flush and padded so that no high byte can sit in the last three
  # bytes of the write:
  #
  #     4-byte big-endian payload length | payload | pad
  #
  # The pad is ASCII and the helper strips it. It is at least MIN_PAD bytes
  # and grows for tiny payloads, so a vulnerable payload always sits behind
  # further ASCII bytes and the write is never shorter than
  # 4 + PAYLOAD_ZONE.
  module SsmPipeFrame
    extend self

    MIN_PAD      =  4
    PAYLOAD_ZONE = 28
    MAX_PAYLOAD  = 64 * 1024
    PAD_BYTE     = 0x4b_u8 # 'K'

    def pad_size(payload_size : Int32) : Int32
      Math.max(MIN_PAD, PAYLOAD_ZONE - payload_size)
    end

    def frame_size(payload_size : Int32) : Int32
      4 + payload_size + pad_size(payload_size)
    end

    def encode(payload : Bytes) : Bytes
      if payload.size > MAX_PAYLOAD
        raise ArgumentError.new("rsync pipe frame payload of #{payload.size} bytes exceeds the maximum")
      end
      frame = Bytes.new(frame_size(payload.size), PAD_BYTE)
      IO::ByteFormat::BigEndian.encode(payload.size.to_u32, frame)
      payload.copy_to(frame + 4)
      frame
    end

    # Incremental decoder: push the raw stream as it arrives, pull complete
    # payloads. Bytes of an incomplete frame stay buffered until the rest
    # arrives; a length beyond *max_payload* means the stream is not ours.
    class Decoder
      def initialize(@max_payload : Int32 = MAX_PAYLOAD)
        @buffer = IO::Memory.new
      end

      def push(bytes : Bytes) : Nil
        @buffer.write(bytes)
      end

      def next_payload : Bytes?
        slice = @buffer.to_slice
        return nil if slice.size < 4
        length = IO::ByteFormat::BigEndian.decode(UInt32, slice[0, 4])
        if length > @max_payload.to_u32
          raise IO::Error.new("rsync pipe frame of #{length} bytes exceeds the bridge's maximum")
        end
        length = length.to_i
        total = SsmPipeFrame.frame_size(length)
        return nil if slice.size < total
        payload = slice[4, length].dup
        # dup: the remainder aliases @buffer's own memory and the write below
        # would otherwise memcpy it over itself (overlap is UB in
        # Slice#copy_to; move_from would be the overlap-safe alternative).
        rest = slice[total..].dup
        @buffer.clear
        @buffer.write(rest)
        payload
      end
    end
  end
end
