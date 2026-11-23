describe "divergence corpus" do
  it "replays 1592-aplyca-deployab-ec2-elb-facts" do
    expected, actual, report = divergence_transcripts(1592, "aplyca-deployab-ec2-elb-facts")
    assert_equal(expected, actual, report)
  end
end
