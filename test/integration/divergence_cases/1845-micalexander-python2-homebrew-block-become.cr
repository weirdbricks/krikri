describe "divergence corpus" do
  it "replays 1845-micalexander-python2-homebrew-block-become" do
    expected, actual, report = divergence_transcripts(1845, "micalexander-python2-homebrew-block-become")
    assert_equal(expected, actual, report)
  end
end
