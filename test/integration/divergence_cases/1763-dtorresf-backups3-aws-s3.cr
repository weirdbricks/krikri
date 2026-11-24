describe "divergence corpus" do
  it "replays 1763-dtorresf-backups3-aws-s3" do
    expected, actual, report = divergence_transcripts(1763, "dtorresf-backups3-aws-s3")
    assert_equal(expected, actual, report)
  end
end
