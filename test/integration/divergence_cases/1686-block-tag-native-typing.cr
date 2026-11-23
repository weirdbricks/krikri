describe "divergence corpus" do
  it "replays 1686-block-tag-native-typing" do
    expected, actual, report = divergence_transcripts(1686, "block-tag-native-typing")
    assert_equal(expected, actual, report)
  end
end
