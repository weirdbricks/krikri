require "../minitest_helper"
require "../../src/krikri/plugin_helpers/crypto_time_spec"

# community.crypto's _time.py get_relative_time_option / the echoed
# datetime spelling, pinned shape-by-shape against ansible-core 2.19.11
# (live-verified through x509_certificate_info's invocation echo).
describe "CryptoTimeSpec" do
  describe "resolve" do
    it "resolves relative specs against UTC now" do
      now = Time.utc
      point = Krikri::CryptoTimeSpec.resolve("+1w").not_nil!
      delta = point - now
      # The two Time.utc calls sit microseconds apart; pin the offset
      # with a wide window.
      (delta.total_days > 6.99 && delta.total_days < 7.01).must_equal(true)
    end

    it "resolves multi-component negative specs component-wise" do
      now = Time.utc
      point = Krikri::CryptoTimeSpec.resolve("-2d3h").not_nil!
      delta = now - point
      (delta.total_hours > 50.99 && delta.total_hours < 51.01).must_equal(true)
    end

    it "resolves +0 to now" do
      now = Time.utc
      point = Krikri::CryptoTimeSpec.resolve("+0").not_nil!
      ((point - now).abs.total_seconds < 1).must_equal(true)
    end

    it "rejects a lone + or - the way convert_relative_to_datetime does" do
      Krikri::CryptoTimeSpec.resolve("+").must_be_nil
      Krikri::CryptoTimeSpec.resolve("-").must_be_nil
    end

    it "rejects components out of sshd_config(5) order" do
      Krikri::CryptoTimeSpec.resolve("+1d1w").must_be_nil
      Krikri::CryptoTimeSpec.resolve("+w").must_be_nil
    end

    it "parses the four absolute shapes, normalizing offsets to UTC" do
      Krikri::CryptoTimeSpec.resolve("20261108000000Z").not_nil!.to_s("%Y-%m-%d %H:%M:%S %z").must_equal("2026-11-08 00:00:00 +0000")
      Krikri::CryptoTimeSpec.resolve("202611081234Z").not_nil!.to_s("%Y-%m-%d %H:%M").must_equal("2026-11-08 12:34")
      # +0200 wall time converts to UTC minus two hours.
      Krikri::CryptoTimeSpec.resolve("20261108123456+0000").not_nil!.to_s("%Y-%m-%d %H:%M:%S").must_equal("2026-11-08 12:34:56")
      Krikri::CryptoTimeSpec.resolve("202611081234+0200").not_nil!.to_s("%Y-%m-%d %H:%M").must_equal("2026-11-08 10:34")
    end

    it "returns nil for anything the four absolute shapes cannot parse" do
      Krikri::CryptoTimeSpec.resolve("20261108000000").must_be_nil
      Krikri::CryptoTimeSpec.resolve("not-a-time").must_be_nil
      Krikri::CryptoTimeSpec.resolve("20261308000000Z").must_be_nil
    end
  end

  describe "echo" do
    it "spells Python's isoformat: fraction omitted at 0 microseconds" do
      time = Time.parse_utc("2026-11-08T00:00:00", "%Y-%m-%dT%H:%M:%S")
      Krikri::CryptoTimeSpec.echo(time, false).must_equal("2026-11-08T00:00:00")
      Krikri::CryptoTimeSpec.echo(time, true).must_equal("2026-11-08T00:00:00+00:00")
    end

    it "prints a 6-digit microsecond fraction when microseconds are nonzero" do
      time = Time.parse_utc("2026-11-08T00:00:00.5", "%Y-%m-%dT%H:%M:%S.%N")
      Krikri::CryptoTimeSpec.echo(time, false).must_equal("2026-11-08T00:00:00.500000")
    end

    it "truncates krikri's nanoseconds to Python's microsecond resolution" do
      time = Time.parse_utc("2026-11-08T00:00:00.123456789", "%Y-%m-%dT%H:%M:%S.%N")
      Krikri::CryptoTimeSpec.echo(time, false).must_equal("2026-11-08T00:00:00.123456")
    end
  end

  describe "python_type_name" do
    it "spells the JSON value's Python class the way {type(v)} interpolates" do
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("5")).must_equal("<class 'int'>")
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("1.5")).must_equal("<class 'float'>")
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("true")).must_equal("<class 'bool'>")
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("null")).must_equal("<class 'NoneType'>")
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("[1]")).must_equal("<class 'list'>")
      Krikri::CryptoTimeSpec.python_type_name(JSON.parse("{}")).must_equal("<class 'dict'>")
    end
  end
end
