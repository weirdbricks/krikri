describe "divergence corpus" do
  it "replays 1858-flatpak-remote-required-before-unsupported" do
    expected, actual, report = divergence_transcripts(1858, "flatpak-remote-required-before-unsupported")
    assert_equal(expected, actual, report)
  end
end
