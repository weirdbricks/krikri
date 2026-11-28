describe "divergence corpus" do
  it "replays 1957-subelements-bare-variable" do
    expected, actual, report = divergence_transcripts(1957, "subelements-bare-variable")
    assert_equal(expected, actual, report)
  end
end
