require "../../src/krikri/plugin_helpers/apache2_module"

private alias Apache2Helper = Krikri::PluginHelpers::Apache2Module

describe Apache2Helper do
  describe ".create_identifier" do
    it "uses the <name>_module convention by default" do
      Apache2Helper.create_identifier("rewrite").should eq("rewrite_module")
      Apache2Helper.create_identifier("ssl").should eq("ssl_module")
      Apache2Helper.create_identifier("mpm_event").should eq("mpm_event_module")
    end

    it "maps shib and shib2 to mod_shib (real module's text workaround)" do
      Apache2Helper.create_identifier("shib").should eq("mod_shib")
      Apache2Helper.create_identifier("shib2").should eq("mod_shib")
      Apache2Helper.create_identifier("shibboleth").should eq("mod_shib")
    end

    it "maps evasive to evasive20_module" do
      Apache2Helper.create_identifier("evasive").should eq("evasive20_module")
    end

    it "maps php8.x spellings to php_module" do
      Apache2Helper.create_identifier("php8.2").should eq("php_module")
      Apache2Helper.create_identifier("php8").should eq("php_module")
    end

    it "maps php7.x-style spellings to their major-version identifier" do
      Apache2Helper.create_identifier("php7.4").should eq("php7_module")
    end

    it "falls back to the convention for a bare php name" do
      Apache2Helper.create_identifier("php").should eq("php_module")
    end
  end
end
