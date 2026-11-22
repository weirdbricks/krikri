require "../minitest_helper"
require "../../src/krikri/ssm_pipe_frame"

describe "Krikri::SsmPipeFrame" do
  it "pads a tiny payload so no high byte can sit near the write's tail" do
    # The real agent's output path holds back a tail of at most three bytes
    # that starts with a high byte (verified: `38 bf 09 6b` arrived as `38`),
    # so the four payload bytes must sit behind ASCII pad bytes.
    payload = Bytes[0x38_u8, 0xbf_u8, 0x09_u8, 0x6b_u8]
    frame = Krikri::SsmPipeFrame.encode(payload)

    frame.size.must_equal(32)
    frame[0, 4].must_equal(Bytes[0_u8, 0_u8, 0_u8, 4_u8])
    frame[4, 4].must_equal(payload)
    frame[8, 24].all? { |byte| byte < 0x80_u8 }.must_equal(true)
  end

  it "keeps a large payload whole and adds only the minimum pad" do
    payload = Bytes.new(1024) { |i| (i % 256).to_u8 }
    frame = Krikri::SsmPipeFrame.encode(payload)

    frame.size.must_equal(4 + 1024 + Krikri::SsmPipeFrame::MIN_PAD)
    frame[4, 1024].must_equal(payload)
    pad = frame[(frame.size - Krikri::SsmPipeFrame::MIN_PAD)..]
    pad.all? { |byte| byte < 0x80_u8 }.must_equal(true)
  end

  it "round-trips payloads that arrive split at arbitrary byte boundaries" do
    first = Krikri::SsmPipeFrame.encode(Bytes[0x38_u8, 0xbf_u8, 0x09_u8, 0x6b_u8])
    second = Krikri::SsmPipeFrame.encode(Bytes[0x41_u8, 0x42_u8])
    stream = IO::Memory.new
    stream.write(first)
    stream.write(second)
    bytes = stream.to_slice

    decoder = Krikri::SsmPipeFrame::Decoder.new
    collected = [] of Bytes
    position = 0
    while position < bytes.size
      count = Math.min(3, bytes.size - position)
      decoder.push(bytes[position, count])
      while payload = decoder.next_payload
        collected << payload
      end
      position += count
    end

    collected.size.must_equal(2)
    collected[0].must_equal(Bytes[0x38_u8, 0xbf_u8, 0x09_u8, 0x6b_u8])
    collected[1].must_equal(Bytes[0x41_u8, 0x42_u8])
  end

  it "holds an incomplete frame until the rest of it arrives" do
    frame = Krikri::SsmPipeFrame.encode(Bytes[0x01_u8])
    decoder = Krikri::SsmPipeFrame::Decoder.new
    decoder.push(frame[0, frame.size - 1])
    decoder.next_payload.must_be_nil
    decoder.push(frame[(frame.size - 1)..])
    decoder.next_payload.must_equal(Bytes[0x01_u8])
  end

  it "refuses a frame whose length exceeds the bridge's maximum" do
    decoder = Krikri::SsmPipeFrame::Decoder.new
    decoder.push(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8])
    assert_raises(IO::Error) { decoder.next_payload }
  end

  it "yields every payload when whole frames and a partial one arrive in one push" do
    # The compaction after a decoded frame must survive a remainder larger
    # than the frame itself (the leftover aliases the decoder's own buffer).
    high = Bytes.new(100) { |i| (0x80_u8 + (i % 8).to_u8) }
    first = Krikri::SsmPipeFrame.encode(Bytes[0x38_u8, 0xbf_u8, 0x09_u8, 0x6b_u8])
    second = Krikri::SsmPipeFrame.encode(high)
    partial = Krikri::SsmPipeFrame.encode(Bytes[0x01_u8])[0, 7]
    stream = IO::Memory.new
    stream.write(first)
    stream.write(second)
    stream.write(partial)

    decoder = Krikri::SsmPipeFrame::Decoder.new
    decoder.push(stream.to_slice)
    collected = [] of Bytes
    while payload = decoder.next_payload
      collected << payload
    end

    collected.size.must_equal(2)
    collected[0].must_equal(Bytes[0x38_u8, 0xbf_u8, 0x09_u8, 0x6b_u8])
    collected[1].must_equal(high)
    decoder.next_payload.must_be_nil
  end

  it "refuses to encode a payload beyond the maximum" do
    oversized = Bytes.new(Krikri::SsmPipeFrame::MAX_PAYLOAD + 1)
    assert_raises(ArgumentError) { Krikri::SsmPipeFrame.encode(oversized) }
  end
end
