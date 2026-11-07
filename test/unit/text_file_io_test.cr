require "../minitest_helper"
require "../../src/krikri/plugin_helpers/text_file_io"

# The failure texts are real ansible-core 2.21.6 runs: lineinfile on a file
# that does not decode raises CPython's UnicodeDecodeError, and its message
# is what the task's msg carries.
describe Krikri::PluginHelpers::TextFileIO do
  it "decodes valid UTF-8 unchanged" do
    Krikri::PluginHelpers::TextFileIO.decode("héllo\n".to_slice, "utf-8").must_equal({"héllo\n", nil})
  end

  it "reports an invalid start byte with CPython's wording" do
    _, error = Krikri::PluginHelpers::TextFileIO.decode(Bytes[0x6f, 0x6b, 0x0a, 0xff], "utf-8")
    error.must_equal("'utf-8' codec can't decode byte 0xff in position 3: invalid start byte")
  end

  it "reports an invalid continuation byte at the offending position" do
    _, error = Krikri::PluginHelpers::TextFileIO.decode(Bytes[0xc3, 0x28], "utf-8")
    error.must_equal("'utf-8' codec can't decode byte 0x28 in position 1: invalid continuation byte")
  end

  it "reports a truncated sequence as unexpected end of data at its start" do
    _, error = Krikri::PluginHelpers::TextFileIO.decode(Bytes[0x61, 0xc3], "utf-8")
    error.must_equal("'utf-8' codec can't decode byte 0xc3 in position 1: unexpected end of data")
  end

  it "round-trips a single-byte encoding through iconv" do
    bytes, error = Krikri::PluginHelpers::TextFileIO.encode("naïve", "iso-8859-1")
    error.must_be_nil
    bytes.hexstring.must_equal("6e61ef7665")

    text, decode_error = Krikri::PluginHelpers::TextFileIO.decode(Bytes[0x6e, 0x61, 0xef, 0x76, 0x65], "iso-8859-1")
    decode_error.must_be_nil
    text.must_equal("naïve")
  end

  it "fails an unknown codec name with Ansible's module-crash wording" do
    Krikri::PluginHelpers::TextFileIO.decode("x\n".to_slice, "20")
      .must_equal({"", "Task failed: Module failed: unknown encoding: 20"})
  end

  it "resolves Python's own codec spellings (latin-1)" do
    text, error = Krikri::PluginHelpers::TextFileIO.decode(Bytes[0x63, 0x61, 0x66, 0xe9], "Latin-1")
    error.must_be_nil
    text.must_equal("café")
  end
end
