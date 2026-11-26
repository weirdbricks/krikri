describe "divergence corpus" do
  it "replays 1856-kpg-filesystem-check-mode-mkfs-probe" do
    expected, actual, report = divergence_transcripts(1856, "kpg-filesystem-check-mode-mkfs-probe")
    assert_equal(expected, actual, report)
  end
end
