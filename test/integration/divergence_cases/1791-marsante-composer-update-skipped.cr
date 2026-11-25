describe "divergence corpus" do
  it "replays 1791-marsante-composer-update-skipped" do
    expected, actual, report = divergence_transcripts(1791, "marsante-composer-update-skipped")
    assert_equal(expected, actual, report)
  end
end
