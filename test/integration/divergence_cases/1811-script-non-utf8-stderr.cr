describe "divergence corpus" do
  it "replays 1811-script-non-utf8-stderr" do
    expected, actual, report = divergence_transcripts(1811, "script-non-utf8-stderr")
    assert_equal(expected, actual, report)
  end
end
