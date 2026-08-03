require "../spec_helper"
require "file_utils"
require "../../src/crystal_play/inventory_parser"

private ROOT = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "inventory_parser_spec")

private def write(path : String, content : String)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
end

private def write_script(path : String, content : String)
  write(path, content)
  File.chmod(path, 0o755)
end

describe CrystalPlay::InventoryParser do
  before_each do
    FileUtils.rm_rf(ROOT) if Dir.exists?(ROOT)
    Dir.mkdir_p(ROOT)
  end

  describe "basic INI parsing" do
    it "parses hosts, inline vars, and group membership" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        [web]
        web1 ansible_user=deploy ansible_port=2222
        INI

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      host = inventory.hosts["web1"]
      host.user.should eq("deploy")
      host.port.should eq(2222)
      inventory.groups["web"].hosts.has_key?("web1").should be_true
    end
  end

  describe "group_vars/host_vars directory loading" do
    it "applies group_vars/all.yml to every host" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        web1
        web2
        INI
      write(File.join(ROOT, "group_vars", "all.yml"), <<-YAML)
        datacenter: dc1
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].vars["datacenter"].as_s.should eq("dc1")
      inventory.hosts["web2"].vars["datacenter"].as_s.should eq("dc1")
    end

    it "applies group_vars/<group>.yml only to that group's hosts" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        [web]
        web1
        [db]
        db1
        INI
      write(File.join(ROOT, "group_vars", "web.yml"), <<-YAML)
        role: webserver
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].vars["role"].as_s.should eq("webserver")
      inventory.hosts["db1"].vars.has_key?("role").should be_false
    end

    it "applies host_vars/<hostname>.yml to just that host" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        web1
        web2
        INI
      write(File.join(ROOT, "host_vars", "web1.yml"), <<-YAML)
        app_version: "1.2.3"
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].vars["app_version"].as_s.should eq("1.2.3")
      inventory.hosts["web2"].vars.has_key?("app_version").should be_false
    end

    it "lets host_vars override group_vars/all for the same key" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        web1
        INI
      write(File.join(ROOT, "group_vars", "all.yml"), <<-YAML)
        env: staging
        YAML
      write(File.join(ROOT, "host_vars", "web1.yml"), <<-YAML)
        env: production
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].vars["env"].as_s.should eq("production")
    end

    it "lets an inline host var win over the same key in host_vars/" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        web1 ansible_user=inline_user
        INI
      write(File.join(ROOT, "host_vars", "web1.yml"), <<-YAML)
        ansible_user: file_user
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].user.should eq("inline_user")
    end

    it "sets ansible_user/ansible_port from a group_vars file" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        [web]
        web1
        INI
      write(File.join(ROOT, "group_vars", "web.yml"), <<-YAML)
        ansible_user: deploy
        ansible_port: 2200
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].user.should eq("deploy")
      inventory.hosts["web1"].port.should eq(2200)
    end

    it "does nothing when no group_vars/host_vars directories exist" do
      write(File.join(ROOT, "inventory.ini"), <<-INI)
        web1
        INI

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "inventory.ini"))

      inventory.hosts["web1"].vars.empty?.should be_true
    end
  end

  describe "dynamic (executable script) inventory" do
    it "is detected by the executable bit, not the filename" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        [ "$1" = "--list" ] && echo '{"web": {"hosts": ["web1"]}}'
        SH

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))

      inventory.hosts.has_key?("web1").should be_true
      inventory.groups["web"].hosts.has_key?("web1").should be_true
    end

    it "parses the full {hosts, vars, children} group format and _meta.hostvars" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        if [ "$1" = "--list" ]; then
        cat <<'JSON'
        {
          "web": {"hosts": ["web1"], "vars": {"role": "webserver"}},
          "db": {"hosts": ["db1"]},
          "prod": {"children": ["web", "db"]},
          "_meta": {"hostvars": {"web1": {"ansible_host": "10.0.0.1"}, "db1": {}}}
        }
        JSON
        fi
        SH

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))

      inventory.hosts["web1"].vars["ansible_host"].as_s.should eq("10.0.0.1")
      inventory.hosts["web1"].vars["role"].as_s.should eq("webserver")
      inventory.groups["prod"].children.should eq(["web", "db"])
    end

    it "parses the shorthand bare-array group format" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        [ "$1" = "--list" ] && echo '{"web": ["web1", "web2"]}'
        SH

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))

      inventory.groups["web"].hosts.keys.sort.should eq(["web1", "web2"])
    end

    it "falls back to --host <name> per host when _meta is absent" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        if [ "$1" = "--list" ]; then
          echo '{"web": ["web1"]}'
        elif [ "$1" = "--host" ]; then
          [ "$2" = "web1" ] && echo '{"ansible_host": "10.0.0.9"}' || echo '{}'
        fi
        SH

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))

      inventory.hosts["web1"].vars["ansible_host"].as_s.should eq("10.0.0.9")
    end

    it "raises a clear error when the script exits non-zero" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        echo "boom" >&2
        exit 1
        SH

      expect_raises(Exception, /Dynamic inventory script.*failed/) do
        CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))
      end
    end

    it "still applies group_vars/host_vars beside the script" do
      write_script(File.join(ROOT, "dynamic-inventory"), <<-SH)
        #!/bin/sh
        [ "$1" = "--list" ] && echo '{"web": {"hosts": ["web1"]}}'
        SH
      write(File.join(ROOT, "group_vars", "all.yml"), <<-YAML)
        datacenter: dc1
        YAML

      inventory = CrystalPlay::InventoryParser.parse(File.join(ROOT, "dynamic-inventory"))

      inventory.hosts["web1"].vars["datacenter"].as_s.should eq("dc1")
    end
  end
end
