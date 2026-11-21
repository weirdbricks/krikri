require "../minitest_helper"
require "../../src/krikri/divergence_transcript"

# The divergence regression corpus: one `it` per case under
# test/fixtures/divergence/<issue>-<slug>/, each asserting that
# krikri-playbook's FULL transcript (stdout followed by stderr, after the
# scratch directory is normalized to <WORK>) equals the transcript real
# ansible-playbook 2.21.6 prints for the same role YAML.
#
# This is deliberately the opposite of the old hand-written regression tests'
# `must_include` assertions: those could only catch MISSING output, so a fix
# that started printing an extra warning block still passed. A corpus case's
# expected.out is captured from real ansible (bin/krikri-capture-case, rules in
# test/fixtures/divergence/README.md) and never from krikri's own output, which
# would enshrine the bug. Normalization, the stdout-then-stderr ordering and the
# failure report come from Krikri::DivergenceTranscript, the same module the
# capture tool writes through.
#
# The suite runs krikri-playbook as a subprocess, exactly like
# inject_facts_deprecation_test.cr.
#
# Cases that cannot run in-process (real package/service/crontab/pip mutation)
# are listed in test/fixtures/divergence/live/cases.txt for a real-host round
# instead, and are not replayed here.
private DIVERGENCE_ROOT   = File.expand_path("../fixtures/divergence", __DIR__)
private DIVERGENCE_BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

# Every corpus case, in capture order. Adding a directory without listing it
# here fails "lists every case directory" below, so a case can never be
# silently skipped.
private DIVERGENCE_CASES = [
  {issue: 1581, slug: "jedimt-vcenter-ovf-ova-index"},
  {issue: 1570, slug: "philnewm-foreman-include-requirements"},
  {issue: 1573, slug: "freebsd-ports-default-fact"},
  {issue: 1572, slug: "mailman3-no-log-loop"},
  {issue: 1568, slug: "el-k3s-slurp-tilde"},
  {issue: 1521, slug: "k8sworker-yaml-parse-case"},
  {issue: 1522, slug: "syncthing-double-slash-include"},
  {issue: 1525, slug: "kasm-server-failed-when"},
  {issue: 1526, slug: "sudo-pair-env-deprecation"},
  {issue: 1528, slug: "reverse-proxy-mandatory"},
  {issue: 1562, slug: "ubuntu-sunjava-action-conflict"},
  {issue: 1569, slug: "juju4-lxdconfigure-debug-ansible-facts-env"},
  {issue: 1575, slug: "amtega-gitlab-fork-get-projects-info"},
  {issue: 1583, slug: "jpedrodelacerda-yay-check-for-base-devel-packages"},
  {issue: 1584, slug: "juju4-lxdconfigure-debug-env-pwd"},
  {issue: 1588, slug: "elk-backup-elasticsearch-plugin"},
  {issue: 1587, slug: "rooland-provisioning-atom-editor-install-atom-editor"},
  {issue: 1592, slug: "aplyca-deployab-ec2-elb-facts"},
  {issue: 1591, slug: "anthony25-postfix-ipwrap"},
  {issue: 1595, slug: "jedimt-customize-vms-hostvars-when"},
  {issue: 1594, slug: "ivansible-cert-cloudflare-reserved-vars"},
  {issue: 1597, slug: "mickengland-ldap-auth-client-debconf-dict"},
  {issue: 1596, slug: "jedimt-haproxy-hostvars-fact"},
  {issue: 1610, slug: "juju4-vivisect-pip-check-executable"},
  {issue: 1602, slug: "wasilak-centos-docker-loop-item-fact"},
  {issue: 1599, slug: "opendevshop-users-bare-fact-defined"},
  {issue: 1593, slug: "dorancemc-ansible-nagioscore-install-rrdtool-packages"},
  {issue: 1600, slug: "stafwag-ntpd-combine-with-provider-defaults"},
  {issue: 1609, slug: "jedimt-haproxy-check-hostvars-fact"},
  {issue: 1603, slug: "anthony25-postfix-generate-postfix-configuration"},
  {issue: 1616, slug: "wabumike-k3s-check-set-fact-parenthesized-filter"},
  {issue: 1606, slug: "dorancemc-nagioscore-nested-defaults"},
  {issue: 1611, slug: "lexa-uw-mailserver-create-volumes-for-mail-data"},
  {issue: 1624, slug: "authorized-key-diff"},
  {issue: 1630, slug: "synchronize-delegate-nonstring-dest"},
  {issue: 1634, slug: "openssl-publickey-malformed-key"},
  {issue: 1633, slug: "openssl-publickey-check-mode"},
  {issue: 1635, slug: "docker-image-api-version-vs-host"},
  {issue: 1637, slug: "docker-network-info-tls-config-vs-api-version"},
  {issue: 1640, slug: "cpanm-name-from-path-mutually-exclusive"},
  {issue: 1640, slug: "cpanm-check-mode-skip"},
  {issue: 1642, slug: "ipr-cnrs-arpwatch-install-recommends"},
  {issue: 1643, slug: "palvarez89-easyrsa3-synchronize-rsync-missing"},
  {issue: 1644, slug: "pgkehle-nvm-reserved-tagnames"},
  {issue: 1645, slug: "standardtech-substrate-assert-chain"},
  {issue: 1647, slug: "artem-shestakov-elasticsearch-exporter-consul-check"},
  {issue: 1648, slug: "hesidoryn-python-coreos-install-python-and-packages"},
  {issue: 1651, slug: "pgkehle-nvm-reserved-tag"},
  {issue: 1646, slug: "command-with-missing-interpreter"},
  {issue: 1641, slug: "hesidoryn-python-coreos-install-python-and-packages"},
  {issue: 1657, slug: "strategy-plugin-retry-fallback"},
  {issue: 1660, slug: "deprecation-warnings-disabled"},
  {issue: 1661, slug: "pacman-bool-type-name"},
]

private def divergence_case_dir(issue : Int32, slug : String) : String
  "#{issue}-#{slug}"
end

# Run krikri-playbook over a copy of the case in private scratch space, the
# way the suite runs every playbook, and return its normalized transcript.
private def replay_divergence_case(issue : Int32, slug : String) : String
  name = divergence_case_dir(issue, slug)
  source = File.join(DIVERGENCE_ROOT, name)
  dir = PluginSpecHelper.tmp_path("divergence-#{name}-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(dir, "home"))
  Dir.children(source).each do |entry|
    # expected.out/NOTES.md are the case's recorded result, not its input.
    next if Krikri::DivergenceCase::RECORDED.includes?(entry)
    FileUtils.cp_r(File.join(source, entry), File.join(dir, entry))
  end

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  # The invocation and environment are Krikri::DivergenceCase's: the case's
  # optional flags.txt/inventory.ini decide the argv, HOME is the case's own
  # scratch dir (a `~/...` path must never reach the developer's real home),
  # an optional env.txt may move the case's own environment, and the
  # fact-gathering env vars are cleared.
  Process.run(
    DIVERGENCE_BINARY,
    Krikri::DivergenceCase.run_args(dir),
    output: stdout,
    error: stderr,
    chdir: dir,
    env: Krikri::DivergenceCase.env(File.join(dir, "home"), dir),
  )

  # stdout then stderr, normalized to <WORK>: the same combine the capture tool
  # writes expected.out with.
  Krikri::DivergenceTranscript.combine(stdout.to_s, stderr.to_s, dir)
end

# The whole point of the corpus: the FULL transcript must equal real ansible's,
# so an extra warning block fails exactly like a missing one. Returns the
# recorded and replayed transcripts plus the failure report, which each `it`
# hands to assert_equal (minitest's assertions are only available inside a
# spec).
private def divergence_transcripts(issue : Int32, slug : String) : {String, String, String}
  name = divergence_case_dir(issue, slug)
  expected = File.read(File.join(DIVERGENCE_ROOT, name, "expected.out"))
  actual = replay_divergence_case(issue, slug)
  {expected, actual, "#{name}: #{Krikri::DivergenceTranscript.report(expected, actual)}"}
end

describe "divergence corpus" do
  it "lists every case directory" do
    on_disk = Dir.children(DIVERGENCE_ROOT)
      .select { |entry| File.directory?(File.join(DIVERGENCE_ROOT, entry)) }
      .reject { |entry| entry == "live" }
      .select { |entry| File.exists?(File.join(DIVERGENCE_ROOT, entry, "playbook.yml")) }
    on_disk.sort!

    listed = DIVERGENCE_CASES.map { |kase| divergence_case_dir(kase[:issue], kase[:slug]) }
    listed.sort!
    on_disk.must_equal(listed)
  end

  it "replays 1581-jedimt-vcenter-ovf-ova-index" do
    expected, actual, report = divergence_transcripts(1581, "jedimt-vcenter-ovf-ova-index")
    assert_equal(expected, actual, report)
  end

  it "replays 1570-philnewm-foreman-include-requirements" do
    expected, actual, report = divergence_transcripts(1570, "philnewm-foreman-include-requirements")
    assert_equal(expected, actual, report)
  end

  it "replays 1573-freebsd-ports-default-fact" do
    expected, actual, report = divergence_transcripts(1573, "freebsd-ports-default-fact")
    assert_equal(expected, actual, report)
  end

  it "replays 1572-mailman3-no-log-loop" do
    expected, actual, report = divergence_transcripts(1572, "mailman3-no-log-loop")
    assert_equal(expected, actual, report)
  end

  it "replays 1568-el-k3s-slurp-tilde" do
    expected, actual, report = divergence_transcripts(1568, "el-k3s-slurp-tilde")
    assert_equal(expected, actual, report)
  end

  it "replays 1521-k8sworker-yaml-parse-case" do
    expected, actual, report = divergence_transcripts(1521, "k8sworker-yaml-parse-case")
    assert_equal(expected, actual, report)
  end

  it "replays 1522-syncthing-double-slash-include" do
    expected, actual, report = divergence_transcripts(1522, "syncthing-double-slash-include")
    assert_equal(expected, actual, report)
  end

  it "replays 1525-kasm-server-failed-when" do
    expected, actual, report = divergence_transcripts(1525, "kasm-server-failed-when")
    assert_equal(expected, actual, report)
  end

  it "replays 1526-sudo-pair-env-deprecation" do
    expected, actual, report = divergence_transcripts(1526, "sudo-pair-env-deprecation")
    assert_equal(expected, actual, report)
  end

  it "replays 1528-reverse-proxy-mandatory" do
    expected, actual, report = divergence_transcripts(1528, "reverse-proxy-mandatory")
    assert_equal(expected, actual, report)
  end

  it "replays 1562-ubuntu-sunjava-action-conflict" do
    expected, actual, report = divergence_transcripts(1562, "ubuntu-sunjava-action-conflict")
    assert_equal(expected, actual, report)
  end

  it "replays 1569-juju4-lxdconfigure-debug-ansible-facts-env" do
    expected, actual, report = divergence_transcripts(1569, "juju4-lxdconfigure-debug-ansible-facts-env")
    assert_equal(expected, actual, report)
  end

  it "replays 1575-amtega-gitlab-fork-get-projects-info" do
    expected, actual, report = divergence_transcripts(1575, "amtega-gitlab-fork-get-projects-info")
    assert_equal(expected, actual, report)
  end

  it "replays 1583-jpedrodelacerda-yay-check-for-base-devel-packages" do
    expected, actual, report = divergence_transcripts(1583, "jpedrodelacerda-yay-check-for-base-devel-packages")
    assert_equal(expected, actual, report)
  end

  it "replays 1584-juju4-lxdconfigure-debug-env-pwd" do
    expected, actual, report = divergence_transcripts(1584, "juju4-lxdconfigure-debug-env-pwd")
    assert_equal(expected, actual, report)
  end

  it "replays 1588-elk-backup-elasticsearch-plugin" do
    expected, actual, report = divergence_transcripts(1588, "elk-backup-elasticsearch-plugin")
    assert_equal(expected, actual, report)
  end

  it "replays 1587-rooland-provisioning-atom-editor-install-atom-editor" do
    expected, actual, report = divergence_transcripts(1587, "rooland-provisioning-atom-editor-install-atom-editor")
    assert_equal(expected, actual, report)
  end

  it "replays 1592-aplyca-deployab-ec2-elb-facts" do
    expected, actual, report = divergence_transcripts(1592, "aplyca-deployab-ec2-elb-facts")
    assert_equal(expected, actual, report)
  end

  it "replays 1591-anthony25-postfix-ipwrap" do
    expected, actual, report = divergence_transcripts(1591, "anthony25-postfix-ipwrap")
    assert_equal(expected, actual, report)
  end

  it "replays 1595-jedimt-customize-vms-hostvars-when" do
    expected, actual, report = divergence_transcripts(1595, "jedimt-customize-vms-hostvars-when")
    assert_equal(expected, actual, report)
  end

  it "replays 1594-ivansible-cert-cloudflare-reserved-vars" do
    expected, actual, report = divergence_transcripts(1594, "ivansible-cert-cloudflare-reserved-vars")
    assert_equal(expected, actual, report)
  end

  it "replays 1597-mickengland-ldap-auth-client-debconf-dict" do
    expected, actual, report = divergence_transcripts(1597, "mickengland-ldap-auth-client-debconf-dict")
    assert_equal(expected, actual, report)
  end

  it "replays 1596-jedimt-haproxy-hostvars-fact" do
    expected, actual, report = divergence_transcripts(1596, "jedimt-haproxy-hostvars-fact")
    assert_equal(expected, actual, report)
  end

  it "replays 1610-juju4-vivisect-pip-check-executable" do
    expected, actual, report = divergence_transcripts(1610, "juju4-vivisect-pip-check-executable")
    assert_equal(expected, actual, report)
  end

  it "replays 1602-wasilak-centos-docker-loop-item-fact" do
    expected, actual, report = divergence_transcripts(1602, "wasilak-centos-docker-loop-item-fact")
    assert_equal(expected, actual, report)
  end

  it "replays 1599-opendevshop-users-bare-fact-defined" do
    expected, actual, report = divergence_transcripts(1599, "opendevshop-users-bare-fact-defined")
    assert_equal(expected, actual, report)
  end

  it "replays 1593-dorancemc-ansible-nagioscore-install-rrdtool-packages" do
    expected, actual, report = divergence_transcripts(1593, "dorancemc-ansible-nagioscore-install-rrdtool-packages")
    assert_equal(expected, actual, report)
  end

  it "replays 1600-stafwag-ntpd-combine-with-provider-defaults" do
    expected, actual, report = divergence_transcripts(1600, "stafwag-ntpd-combine-with-provider-defaults")
    assert_equal(expected, actual, report)
  end

  it "replays 1609-jedimt-haproxy-check-hostvars-fact" do
    expected, actual, report = divergence_transcripts(1609, "jedimt-haproxy-check-hostvars-fact")
    assert_equal(expected, actual, report)
  end

  it "replays 1603-anthony25-postfix-generate-postfix-configuration" do
    expected, actual, report = divergence_transcripts(1603, "anthony25-postfix-generate-postfix-configuration")
    assert_equal(expected, actual, report)
  end

  it "replays 1616-wabumike-k3s-check-set-fact-parenthesized-filter" do
    expected, actual, report = divergence_transcripts(1616, "wabumike-k3s-check-set-fact-parenthesized-filter")
    assert_equal(expected, actual, report)
  end

  it "replays 1606-dorancemc-nagioscore-nested-defaults" do
    expected, actual, report = divergence_transcripts(1606, "dorancemc-nagioscore-nested-defaults")
    assert_equal(expected, actual, report)
  end

  it "replays 1611-lexa-uw-mailserver-create-volumes-for-mail-data" do
    expected, actual, report = divergence_transcripts(1611, "lexa-uw-mailserver-create-volumes-for-mail-data")
    assert_equal(expected, actual, report)
  end

  it "replays 1624-authorized-key-diff" do
    expected, actual, report = divergence_transcripts(1624, "authorized-key-diff")
    assert_equal(expected, actual, report)
  end

  it "replays 1630-synchronize-delegate-nonstring-dest" do
    expected, actual, report = divergence_transcripts(1630, "synchronize-delegate-nonstring-dest")
    assert_equal(expected, actual, report)
  end

  it "replays 1634-openssl-publickey-malformed-key" do
    expected, actual, report = divergence_transcripts(1634, "openssl-publickey-malformed-key")
    assert_equal(expected, actual, report)
  end

  it "replays 1633-openssl-publickey-check-mode" do
    expected, actual, report = divergence_transcripts(1633, "openssl-publickey-check-mode")
    assert_equal(expected, actual, report)
  end

  it "replays 1635-docker-image-api-version-vs-host" do
    expected, actual, report = divergence_transcripts(1635, "docker-image-api-version-vs-host")
    assert_equal(expected, actual, report)
  end

  it "replays 1637-docker-network-info-tls-config-vs-api-version" do
    expected, actual, report = divergence_transcripts(1637, "docker-network-info-tls-config-vs-api-version")
    assert_equal(expected, actual, report)
  end

  it "replays 1640-cpanm-name-from-path-mutually-exclusive" do
    expected, actual, report = divergence_transcripts(1640, "cpanm-name-from-path-mutually-exclusive")
    assert_equal(expected, actual, report)
  end

  it "replays 1640-cpanm-check-mode-skip" do
    expected, actual, report = divergence_transcripts(1640, "cpanm-check-mode-skip")
    assert_equal(expected, actual, report)
  end

  it "replays 1642-ipr-cnrs-arpwatch-install-recommends" do
    expected, actual, report = divergence_transcripts(1642, "ipr-cnrs-arpwatch-install-recommends")
    assert_equal(expected, actual, report)
  end

  it "replays 1643-palvarez89-easyrsa3-synchronize-rsync-missing" do
    expected, actual, report = divergence_transcripts(1643, "palvarez89-easyrsa3-synchronize-rsync-missing")
    assert_equal(expected, actual, report)
  end

  it "replays 1644-pgkehle-nvm-reserved-tagnames" do
    expected, actual, report = divergence_transcripts(1644, "pgkehle-nvm-reserved-tagnames")
    assert_equal(expected, actual, report)
  end

  it "replays 1645-standardtech-substrate-assert-chain" do
    expected, actual, report = divergence_transcripts(1645, "standardtech-substrate-assert-chain")
    assert_equal(expected, actual, report)
  end

  it "replays 1647-artem-shestakov-elasticsearch-exporter-consul-check" do
    expected, actual, report = divergence_transcripts(1647, "artem-shestakov-elasticsearch-exporter-consul-check")
    assert_equal(expected, actual, report)
  end

  it "replays 1648-hesidoryn-python-coreos-install-python-and-packages" do
    expected, actual, report = divergence_transcripts(1648, "hesidoryn-python-coreos-install-python-and-packages")
    assert_equal(expected, actual, report)
  end

  it "replays 1651-pgkehle-nvm-reserved-tag" do
    expected, actual, report = divergence_transcripts(1651, "pgkehle-nvm-reserved-tag")
    assert_equal(expected, actual, report)
  end

  it "replays 1646-command-with-missing-interpreter" do
    expected, actual, report = divergence_transcripts(1646, "command-with-missing-interpreter")
    assert_equal(expected, actual, report)
  end

  it "replays 1641-hesidoryn-python-coreos-install-python-and-packages" do
    expected, actual, report = divergence_transcripts(1641, "hesidoryn-python-coreos-install-python-and-packages")
    assert_equal(expected, actual, report)
  end

  it "replays 1657-strategy-plugin-retry-fallback" do
    expected, actual, report = divergence_transcripts(1657, "strategy-plugin-retry-fallback")
    assert_equal(expected, actual, report)
  end

  it "replays 1660-deprecation-warnings-disabled" do
    expected, actual, report = divergence_transcripts(1660, "deprecation-warnings-disabled")
    assert_equal(expected, actual, report)
  end

  it "replays 1661-pacman-bool-type-name" do
    expected, actual, report = divergence_transcripts(1661, "pacman-bool-type-name")
    assert_equal(expected, actual, report)
  end
end
