describe "divergence corpus" do
  it "replays 1706-set-fact-assert-include-vars-run" do
    expected, actual, report = divergence_transcripts(1706, "set-fact-assert-include-vars-run")
    assert_equal(expected, actual, report)
  end
end
