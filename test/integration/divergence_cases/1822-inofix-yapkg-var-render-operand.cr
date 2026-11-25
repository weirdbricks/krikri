describe "divergence corpus" do
  it "replays 1822-inofix-yapkg-var-render-operand" do
    expected, actual, report = divergence_transcripts(1822, "inofix-yapkg-var-render-operand")
    assert_equal(expected, actual, report)
  end
end
