describe "divergence corpus" do
  it "replays 1842-barraponto-aws-vpc-ec2-vpc" do
    expected, actual, report = divergence_transcripts(1842, "barraponto-aws-vpc-ec2-vpc")
    assert_equal(expected, actual, report)
  end
end
