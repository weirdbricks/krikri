describe "divergence corpus" do
  it "replays 1595-jedimt-customize-vms-hostvars-when" do
    expected, actual, report = divergence_transcripts(1595, "jedimt-customize-vms-hostvars-when")
    assert_equal(expected, actual, report)
  end
end
