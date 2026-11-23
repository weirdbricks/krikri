describe "divergence corpus" do
  it "replays 1599-opendevshop-users-bare-fact-defined" do
    expected, actual, report = divergence_transcripts(1599, "opendevshop-users-bare-fact-defined")
    assert_equal(expected, actual, report)
  end
end
