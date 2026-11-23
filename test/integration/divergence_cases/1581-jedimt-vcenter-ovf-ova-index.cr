describe "divergence corpus" do
  it "replays 1581-jedimt-vcenter-ovf-ova-index" do
    expected, actual, report = divergence_transcripts(1581, "jedimt-vcenter-ovf-ova-index")
    assert_equal(expected, actual, report)
  end
end
