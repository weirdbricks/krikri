require "../minitest_helper"

# Regression test for issue #1726: krikri-aws-ssm's STS client once
# parsed AWS's Query-protocol answers with Crystal's stdlib XML, which
# links libxml2.so.2 - and base_plugin -> ssh_manager -> ssm_transport
# -> krikri-aws-ssm pulled that into every plugin binary, i.e. onto the
# hosts those plugins are uploaded to. A stock Ubuntu image has no
# libxml2.so.2 (round 29923741's
# alesauce.provision_new_stock_linux_server): real ansible's
# Gathering Facts, pure Python, returned ok there, while krikri's facts
# plugin died inside the dynamic loader before main() ran and the play
# failed at facts. The STS client now parses with krikri-xml, the
# project's pure-Crystal XML implementation, so nothing in a plugin may
# ask the loader for libxml2 again. Skips when readelf or the built
# binaries are absent (macOS, musl/static builds, or a checkout that
# never ran build.sh).
describe "plugin shared libraries" do
  it "loads no libxml2 shared library at startup" do
    skip "readelf not available" if `command -v readelf 2>/dev/null`.empty?
    # bin/plugins/facts is a hardlink to .fat-plugin - the binary every
    # remote host actually receives - plus one standalone for the
    # separately compiled plugin shape.
    binaries = ["bin/plugins/.fat-plugin", "bin/plugins/debug"].select { |path| File.file?(path) }
    skip "binaries not built" if binaries.empty?

    binaries.each do |binary|
      needed = `readelf -d #{binary} 2>/dev/null`.scan(/\(NEEDED\).*\[([^\]]*)\]/).map { |match| match[1] }
      offenders = needed.select { |library| library.includes?("libxml2") }
      assert_empty offenders, "#{binary} still resolves libxml2 dynamically: #{offenders.join(", ")}"
    end
  end
end
