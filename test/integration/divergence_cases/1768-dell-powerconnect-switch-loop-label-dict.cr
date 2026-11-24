describe "divergence corpus" do
  it "replays 1768-dell-powerconnect-switch-loop-label-dict" do
    expected, actual, report = divergence_transcripts(1768, "dell-powerconnect-switch-loop-label-dict")
    assert_equal(expected, actual, report)
  end
end
