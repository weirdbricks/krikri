describe "divergence corpus" do
  it "replays 1758-external-plugin-typed-args" do
    expected, actual, report = divergence_transcripts(1758, "external-plugin-typed-args")
    assert_equal(expected, actual, report)
  end
end
