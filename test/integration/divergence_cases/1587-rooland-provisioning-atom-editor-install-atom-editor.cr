describe "divergence corpus" do
  it "replays 1587-rooland-provisioning-atom-editor-install-atom-editor" do
    expected, actual, report = divergence_transcripts(1587, "rooland-provisioning-atom-editor-install-atom-editor")
    assert_equal(expected, actual, report)
  end
end
