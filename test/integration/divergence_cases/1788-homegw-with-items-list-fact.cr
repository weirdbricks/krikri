describe "divergence corpus" do
  it "replays 1788-homegw-with-items-list-fact" do
    expected, actual, report = divergence_transcripts(1788, "homegw-with-items-list-fact")
    assert_equal(expected, actual, report)
  end
end
