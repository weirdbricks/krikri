describe "divergence corpus" do
  it "replays 1583-jpedrodelacerda-yay-check-for-base-devel-packages" do
    expected, actual, report = divergence_transcripts(1583, "jpedrodelacerda-yay-check-for-base-devel-packages")
    assert_equal(expected, actual, report)
  end
end
