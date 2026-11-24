require "../minitest_helper"

# Regression test for issue #164: binaries linked on a glibc >= 2.38
# host used to carry version requirements for GLIBC_2.38+ symbol nodes
# (libm fmod, the C23 strtol family) and refused to start on older
# targets like Rocky 9. scripts/fmod_compat.s shims those symbols;
# this asserts no GLIBC_2.38+ requirement survives the build. Skips
# when objdump or the built binaries are absent (e.g. static or musl
# builds, or a test checkout that never ran build.sh).
describe "glibc symbol versions" do
  it "has no GLIBC_2.38+ version requirements in built binaries" do
    if `command -v objdump 2>/dev/null`.empty?
      if ENV["CI"]?
        flunk "objdump is required: the glibc symbol contract cannot be checked without it"
      else
        skip "objdump not available"
      end
    end
    binaries = ["bin/krikri-playbook", "bin/plugins/facts"].select { |path| File.file?(path) }
    if binaries.empty?
      if ENV["CI"]?
        flunk "no binaries built: run ./build.sh before the test suite"
      else
        skip "binaries not built"
      end
    end

    binaries.each do |binary|
      output = `objdump -T #{binary} 2>/dev/null`
      matches = output.scan(/\(GLIBC_2\.(?:3[89]|4\d)\)\s+(\S+)/)
      names = matches.map { |match| match[1] }
      offenders = names.uniq
      assert_empty offenders, "#{binary} still requires GLIBC_2.38+ symbols: #{offenders.join(", ")}"
    end
  end
end
