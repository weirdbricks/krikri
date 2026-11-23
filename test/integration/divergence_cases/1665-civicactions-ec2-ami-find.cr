describe "divergence corpus" do
  it "replays 1665-civicactions-ec2-ami-find" do
    expected, actual, report = divergence_transcripts(1665, "civicactions-ec2-ami-find")
    assert_equal(expected, actual, report)
  end
end
