describe "divergence corpus" do
  it "replays 1679-onelove-roles-freebsd-consul-template-pkgng-check" do
    expected, actual, report = divergence_transcripts(1679, "onelove-roles-freebsd-consul-template-pkgng-check")
    assert_equal(expected, actual, report)
  end
end
