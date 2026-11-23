describe "divergence corpus" do
  it "replays 1570-philnewm-foreman-include-requirements" do
    expected, actual, report = divergence_transcripts(1570, "philnewm-foreman-include-requirements")
    assert_equal(expected, actual, report)
  end
end
