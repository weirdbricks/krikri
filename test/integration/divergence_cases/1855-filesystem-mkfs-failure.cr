describe "divergence corpus" do
  it "replays 1855-filesystem-mkfs-failure" do
    expected, actual, report = divergence_transcripts(1855, "filesystem-mkfs-failure")
    assert_equal(expected, actual, report)
  end
end
