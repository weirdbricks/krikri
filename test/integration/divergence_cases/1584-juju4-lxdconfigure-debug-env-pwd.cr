describe "divergence corpus" do
  it "replays 1584-juju4-lxdconfigure-debug-env-pwd" do
    expected, actual, report = divergence_transcripts(1584, "juju4-lxdconfigure-debug-env-pwd")
    assert_equal(expected, actual, report)
  end
end
