describe "divergence corpus" do
  it "replays 1911-delete-existing-docker-compose-version-if-it-s-different" do
    expected, actual, report = divergence_transcripts(1911, "delete-existing-docker-compose-version-if-it-s-different")
    assert_equal(expected, actual, report)
  end
end
