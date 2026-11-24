describe "divergence corpus" do
  it "replays 1766-lerwys-logrotate-task-var-fact-origin" do
    expected, actual, report = divergence_transcripts(1766, "lerwys-logrotate-task-var-fact-origin")
    assert_equal(expected, actual, report)
  end
end
