describe "divergence corpus" do
  it "replays 1853-path-join-undefined-tuple-operand" do
    expected, actual, report = divergence_transcripts(1853, "path-join-undefined-tuple-operand")
    assert_equal(expected, actual, report)
  end
end
