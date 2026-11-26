describe "divergence corpus" do
  it "replays 1837-jsonfile-fact-cache-ansible-layout" do
    expected, actual, report = divergence_transcripts(1837, "jsonfile-fact-cache-ansible-layout")
    assert_equal(expected, actual, report)
  end
end
