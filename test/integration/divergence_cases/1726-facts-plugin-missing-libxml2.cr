describe "divergence corpus" do
  it "replays 1726-facts-plugin-missing-libxml2" do
    expected, actual, report = divergence_transcripts(1726, "facts-plugin-missing-libxml2")
    assert_equal(expected, actual, report)
  end
end
