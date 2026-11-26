describe "divergence corpus" do
  it "replays 1857-flatpak-remote-state-before-unsupported-params" do
    expected, actual, report = divergence_transcripts(1857, "flatpak-remote-state-before-unsupported-params")
    assert_equal(expected, actual, report)
  end
end
