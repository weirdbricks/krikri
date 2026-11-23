describe "divergence corpus" do
  it "replays 1591-anthony25-postfix-ipwrap" do
    expected, actual, report = divergence_transcripts(1591, "anthony25-postfix-ipwrap")
    assert_equal(expected, actual, report)
  end
end
