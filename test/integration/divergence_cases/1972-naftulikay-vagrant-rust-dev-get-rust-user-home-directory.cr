describe "divergence corpus" do
  it "replays 1972-naftulikay-vagrant-rust-dev-get-rust-user-home-directory" do
    expected, actual, report = divergence_transcripts(1972, "naftulikay-vagrant-rust-dev-get-rust-user-home-directory")
    assert_equal(expected, actual, report)
  end
end
