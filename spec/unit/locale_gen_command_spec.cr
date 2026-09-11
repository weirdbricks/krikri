require "../spec_helper"
require "../../src/krikri/plugin_helpers/locale_gen_command"

# Unit-tests community.general.locale_gen's pure string logic (read
# from a live collection install) - the normalization table, the
# /usr/share/i18n/SUPPORTED entry matcher, and the /etc/locale.gen
# rewrite. Actually generating locales needs a Debian/Ubuntu host with
# the `locales` package, so that is exercised by the live benchmark
# rounds only.
describe Krikri::PluginHelpers::LocaleGenCommand do
  describe ".fix_case" do
    it "folds the encodings real `locale -a` reports in either case" do
      Krikri::PluginHelpers::LocaleGenCommand.fix_case("en_US.utf8").should eq("en_US.UTF-8")
      Krikri::PluginHelpers::LocaleGenCommand.fix_case("en_US.UTF-8").should eq("en_US.UTF-8")
      Krikri::PluginHelpers::LocaleGenCommand.fix_case("de_DE.iso885915").should eq("de_DE.ISO-8859-15")
      Krikri::PluginHelpers::LocaleGenCommand.fix_case("ru_RU.koi8r").should eq("ru_RU.KOI8-R")
    end
  end

  describe ".supported_entry_locale" do
    it "matches a plain SUPPORTED entry line" do
      Krikri::PluginHelpers::LocaleGenCommand.supported_entry_locale("en_US.UTF-8 UTF-8")
        .should eq("en_US.UTF-8")
    end

    it "matches a commented-out entry line" do
      Krikri::PluginHelpers::LocaleGenCommand.supported_entry_locale("# nl_NL.UTF-8 UTF-8")
        .should eq("nl_NL.UTF-8")
    end

    it "returns nil for a non-entry line" do
      Krikri::PluginHelpers::LocaleGenCommand.supported_entry_locale("# /etc/i18n")
        .should be_nil
    end
  end

  describe ".locale_available?" do
    supported = [
      "# en_US.UTF-8 UTF-8",
      "# nl_NL.UTF-8 UTF-8",
      "# de_DE.ISO-8859-1 ISO-8859-1",
    ]

    it "accepts a locale listed in SUPPORTED even when commented out" do
      Krikri::PluginHelpers::LocaleGenCommand.locale_available?("nl_NL.UTF-8", supported, "")
        .should be_true
    end

    it "accepts a locale already compiled but absent from SUPPORTED (C.UTF-8)" do
      Krikri::PluginHelpers::LocaleGenCommand.locale_available?("C.UTF-8", supported, "C\nC.utf8\nPOSIX\n")
        .should be_true
    end

    it "compares encodings case-insensitively via the normalization table" do
      Krikri::PluginHelpers::LocaleGenCommand.locale_available?("C.UTF-8", supported, "C\nC.utf8\nPOSIX\n")
        .should be_true
    end

    it "rejects a locale in neither place" do
      Krikri::PluginHelpers::LocaleGenCommand.locale_available?("xx_YY.ZZZ", supported, "C\nPOSIX\n")
        .should be_false
    end
  end

  describe ".rewrite_locale_gen" do
    lines = [
      "#  Generated configuration file",
      "en_US.UTF-8 UTF-8",
      "# nl_NL.UTF-8 UTF-8",
      "# de_CH.UTF-8 UTF-8",
    ]

    it "uncomments the requested locale, preserving the charset column" do
      result = Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(lines, ["de_CH.UTF-8"], enabled: true)
      result.should eq([
        "#  Generated configuration file",
        "en_US.UTF-8 UTF-8",
        "# nl_NL.UTF-8 UTF-8",
        "de_CH.UTF-8 UTF-8",
      ])
    end

    it "comments out the requested locale" do
      result = Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(lines, ["en_US.UTF-8"], enabled: false)
      result[1].should eq("# en_US.UTF-8 UTF-8")
      result[2].should eq("# nl_NL.UTF-8 UTF-8")
    end

    it "is idempotent for a line already in the requested state" do
      Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(lines, ["en_US.UTF-8"], enabled: true)
        .should eq(lines)
      commented = Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(lines, ["nl_NL.UTF-8"], enabled: false)
      Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(commented, ["nl_NL.UTF-8"], enabled: false)
        .should eq(commented)
    end

    it "leaves lines for other locales untouched" do
      result = Krikri::PluginHelpers::LocaleGenCommand.rewrite_locale_gen(lines, ["de_CH.UTF-8"], enabled: true)
      result[0].should eq(lines[0])
      result[1].should eq(lines[1])
      result[2].should eq(lines[2])
    end
  end
end
