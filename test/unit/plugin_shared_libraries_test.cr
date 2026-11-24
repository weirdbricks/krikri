require "../minitest_helper"

# Regression coverage for issues #164 and #1726: every plugin binary is
# uploaded to a target host and must start there, so its dynamic dependency
# set is a hard requirement on the target's package baseline. Crystal's
# stdlib XML once put libxml2.so.2 here through krikri-aws-ssm, and a stock
# Ubuntu image has no libxml2, so the loader killed the plugin before main()
# ran: Gathering Facts failed where real ansible's Python facts succeed. A
# build host with glibc >= 2.38 did the same with GLIBC_2.38 symbol versions
# on Rocky 9 (see glibc_symbol_version_test.cr).
#
# The contract is deliberately broader than that one library: a plugin may
# link only the shared libraries the declared target baseline provides. A
# new native dependency in any shard reaches every plugin through
# base_plugin, so it has to be added here deliberately (and to
# krikri-role-tester's GuestBaseline packages, and the release workflow's
# bare-target smoke gate) instead of being discovered on a customer's host.
describe "plugin load linkage" do
  # Keep in step with krikri-role-tester's GuestBaseline::PACKAGES and the
  # baseline container the CI/release workflows run the plugins in.
  TARGET_BASELINE_SONAMES = Set{
    "libc.so.6", "libm.so.6", "libgcc_s.so.1", "libpthread.so.0",
    "libdl.so.2", "librt.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
    "libz.so.1", "liblzma.so.5", "libssl.so.3", "libcrypto.so.3",
    "libyaml-0.so.2", "libgmp.so.10", "libpcre2-8.so.0",
  }

  # bin/plugins/.fat-plugin is the binary every remote host receives; the
  # other names are hardlinks to it (bin/plugins/debug is compiled apart).
  # Dedupe by inode so each real binary is checked once.
  private def plugin_binaries : Array(String)
    seen = Set(String).new
    (["bin/plugins/.fat-plugin"] + Dir.glob("bin/plugins/*")).compact_map do |path|
      next unless File.file?(path)
      # GNU stat's inode; a platform without it falls back to the path, which
      # only costs a repeated readelf for a hardlink.
      inode = `stat -Lc %i #{Process.quote(path)} 2>/dev/null`.strip
      key = inode.empty? ? path : inode
      next if seen.includes?(key)
      seen << key
      path
    end
  end

  it "links only libraries the declared target baseline provides" do
    binaries = plugin_binaries
    if `command -v readelf 2>/dev/null`.empty?
      if ENV["CI"]?
        flunk "readelf is required: the plugin linkage contract cannot be checked without it"
      else
        skip "readelf not available"
      end
    end
    if binaries.empty?
      if ENV["CI"]?
        flunk "no plugin binaries built: run ./build.sh before the test suite"
      else
        skip "binaries not built"
      end
    end

    binaries.each do |binary|
      needed = `readelf -d #{binary} 2>/dev/null`.scan(/\(NEEDED\).*\[([^\]]*)\]/).map { |match| match[1] }
      # A fully static build has no NEEDED entries at all; that satisfies the
      # contract trivially and is what the release tarball ships.
      offenders = needed.reject { |library| TARGET_BASELINE_SONAMES.includes?(library) }
      assert_empty offenders,
        "#{binary} links shared libraries the target baseline does not provide: #{offenders.join(", ")}. " \
        "Use krikri-xml instead of Crystal's stdlib XML, or add the library to the baseline deliberately."
    end
  end
end
