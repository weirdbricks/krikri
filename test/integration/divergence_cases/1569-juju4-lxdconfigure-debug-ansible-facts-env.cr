describe "divergence corpus" do
  it "replays 1569-juju4-lxdconfigure-debug-ansible-facts-env" do
    expected, actual, report = divergence_transcripts(1569, "juju4-lxdconfigure-debug-ansible-facts-env")
    assert_equal(expected, actual, report)
  end
end
