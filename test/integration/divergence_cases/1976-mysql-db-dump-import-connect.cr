describe "divergence corpus" do
  it "replays 1976-mysql-db-dump-import-connect" do
    expected, actual, report = divergence_transcripts(1976, "mysql-db-dump-import-connect")
    assert_equal(expected, actual, report)
  end
end
