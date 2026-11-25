describe "divergence corpus" do
  it "replays 1806-copy-validate-keeps-existing-dest-mode" do
    expected, actual, report = divergence_transcripts(1806, "copy-validate-keeps-existing-dest-mode")
    assert_equal(expected, actual, report)
  end
end
