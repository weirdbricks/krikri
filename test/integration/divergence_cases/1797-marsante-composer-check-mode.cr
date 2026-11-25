describe "divergence corpus" do
  it "replays 1797-marsante-composer-check-mode" do
    expected, actual, report = divergence_transcripts(1797, "marsante-composer-check-mode")
    assert_equal(expected, actual, report)
  end
end
