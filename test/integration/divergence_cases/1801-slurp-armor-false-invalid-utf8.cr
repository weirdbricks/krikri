describe "divergence corpus" do
  it "replays 1801-slurp-armor-false-invalid-utf8" do
    expected, actual, report = divergence_transcripts(1801, "slurp-armor-false-invalid-utf8")
    assert_equal(expected, actual, report)
  end
end
