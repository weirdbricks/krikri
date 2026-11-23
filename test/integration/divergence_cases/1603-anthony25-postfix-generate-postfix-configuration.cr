describe "divergence corpus" do
  it "replays 1603-anthony25-postfix-generate-postfix-configuration" do
    expected, actual, report = divergence_transcripts(1603, "anthony25-postfix-generate-postfix-configuration")
    assert_equal(expected, actual, report)
  end
end
