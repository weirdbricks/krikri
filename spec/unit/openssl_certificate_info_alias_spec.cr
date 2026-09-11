require "../spec_helper"
require "../../src/krikri/playbook_parser"

# openssl_certificate_info is x509_certificate_info's old name - the
# same deprecated-redirect rename story as openssl_certificate ->
# x509_certificate (community.crypto 1.0.0). Every spelling a real
# controller still resolves must land on the existing
# x509_certificate_info plugin binary. Found as a hard-stop in the
# ufz.zammad round (410129), which writes the bare spelling.
describe "openssl_certificate_info alias" do
  [
    "openssl_certificate_info",
    "ansible.builtin.openssl_certificate_info",
    "ansible.legacy.openssl_certificate_info",
    "community.crypto.openssl_certificate_info",
    "community.general.openssl_certificate_info",
  ].each do |spelling|
    it "resolves #{spelling} onto x509_certificate_info" do
      Krikri::PlaybookParser.resolve_module_name(spelling)
        .should eq("community.crypto.x509_certificate_info")
    end
  end

  it "still resolves the canonical spelling" do
    Krikri::PlaybookParser.resolve_module_name("community.crypto.x509_certificate_info")
      .should eq("community.crypto.x509_certificate_info")
  end

  it "resolves the bare canonical spelling through collection search" do
    Krikri::PlaybookParser.resolve_module_name("x509_certificate_info")
      .should eq("community.crypto.x509_certificate_info")
  end
end
