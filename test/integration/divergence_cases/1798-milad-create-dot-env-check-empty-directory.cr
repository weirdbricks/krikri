describe "divergence corpus" do
  it "replays 1798-milad-create-dot-env-check-empty-directory" do
    expected, actual, report = divergence_transcripts(1798, "milad-create-dot-env-check-empty-directory")
    assert_equal(expected, actual, report)
  end
end
