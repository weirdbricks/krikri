describe "divergence corpus" do
  it "replays 1909-jedimt-nebulon-manage-volumes-neb-npod-info" do
    expected, actual, report = divergence_transcripts(1909, "jedimt-nebulon-manage-volumes-neb-npod-info")
    assert_equal(expected, actual, report)
  end
end
