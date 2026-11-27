describe "divergence corpus" do
  it "replays 1907-when-quoted-template-unknown-filter" do
    expected, actual, report = divergence_transcripts(1907, "when-quoted-template-unknown-filter")
    assert_equal(expected, actual, report)
  end
end
