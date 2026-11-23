describe "divergence corpus" do
  it "replays 1667-postgres-exporter-selinux-package-fact-origin" do
    expected, actual, report = divergence_transcripts(1667, "postgres-exporter-selinux-package-fact-origin")
    assert_equal(expected, actual, report)
  end
end
