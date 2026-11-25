describe "divergence corpus" do
  it "replays 1824-jedimt-ssh-known-hosts-groups-origin" do
    expected, actual, report = divergence_transcripts(1824, "jedimt-ssh-known-hosts-groups-origin")
    assert_equal(expected, actual, report)
  end
end
