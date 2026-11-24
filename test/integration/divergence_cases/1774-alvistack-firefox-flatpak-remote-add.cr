describe "divergence corpus" do
  it "replays 1774-alvistack-firefox-flatpak-remote-add" do
    expected, actual, report = divergence_transcripts(1774, "alvistack-firefox-flatpak-remote-add")
    assert_equal(expected, actual, report)
  end
end
