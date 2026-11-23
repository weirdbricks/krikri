describe "divergence corpus" do
  it "replays 1635-docker-image-api-version-vs-host" do
    expected, actual, report = divergence_transcripts(1635, "docker-image-api-version-vs-host")
    assert_equal(expected, actual, report)
  end
end
