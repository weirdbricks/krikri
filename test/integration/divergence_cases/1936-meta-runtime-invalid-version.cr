describe "divergence corpus" do
  it "replays 1936-meta-runtime-invalid-version" do
    expected, actual, report = divergence_transcripts(1936, "meta-runtime-invalid-version")
    assert_equal(expected, actual, report)
  end
end
