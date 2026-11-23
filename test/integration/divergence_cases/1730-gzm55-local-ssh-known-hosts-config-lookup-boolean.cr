describe "divergence corpus" do
  it "replays 1730-gzm55-local-ssh-known-hosts-config-lookup-boolean" do
    expected, actual, report = divergence_transcripts(1730, "gzm55-local-ssh-known-hosts-config-lookup-boolean")
    assert_equal(expected, actual, report)
  end
end
