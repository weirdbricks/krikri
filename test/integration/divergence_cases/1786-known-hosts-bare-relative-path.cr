describe "divergence corpus" do
  it "replays 1786-known-hosts-bare-relative-path" do
    expected, actual, report = divergence_transcripts(1786, "known-hosts-bare-relative-path")
    assert_equal(expected, actual, report)
  end
end
