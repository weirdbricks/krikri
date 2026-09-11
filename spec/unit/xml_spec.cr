require "../spec_helper"
require "json"

# Unit-tests the community.general.xml plugin through its real binary
# entrypoint (the same way PluginManager invokes it). The module's core
# value is the lxml/libxml2 semantics - xpath mutation, auto-creation of
# missing parent elements, idempotency, namespace handling - so the spec
# drives real files on disk, mirroring the corpus roles' own usage
# (alvistack/buluma Atlassian web.xml patching, Saltbox config.xml
# editing, and the upstream module's own documented examples).
def run_xml(params : JSON::Any) : JSON::Any
  binary = File.join(PluginSpecHelper::PLUGINS_DIR, "xml")
  raise "Plugin binary not found: #{binary} (run ./build.sh first)" unless File.exists?(binary)

  config = {
    "host"   => {"name" => "localhost", "user" => ENV["USER"]? || "root", "port" => 22},
    "params" => params,
    "vars"   => {} of String => String,
  }

  output = IO::Memory.new
  Process.run(binary, input: Process::Redirect::Pipe, output: output, error: Process::Redirect::Inherit) do |process|
    process.input.print(config.to_json)
    process.input.close
  end

  JSON.parse(output.to_s)
end

def xml_params(hash : Hash(String, String)) : JSON::Any
  JSON.parse(hash.to_json)
end

describe "community.general.xml plugin" do
  describe "value set (state: present)" do
    it "sets element text and reports changed" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<?xml version="1.0" encoding="UTF-8"?>\n<business><rating>10</rating></business>\n))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "value" => "11"}))
      result["changed"].should be_true
      File.read(path).should contain("<rating>11</rating>")
      File.delete(path)
    end

    it "is idempotent on rerun" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<?xml version="1.0" encoding="UTF-8"?>\n<business><rating>11</rating></business>\n))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "value" => "11"}))
      result["changed"].should be_false
      File.delete(path)
    end

    it "auto-creates missing elements with parent chain" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/website/validxhtml"}))
      result["changed"].should be_true
      content = File.read(path)
      content.should contain("<website>")
      content.should contain("<validxhtml/>")
      File.delete(path)
    end

    it "respects create_if_missing: false as a no-op on no match" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/missing", "value" => "x", "create_if_missing" => "false"}))
      result["changed"].should be_false
      result["failed"].should be_false
      File.read(path).should_not contain("missing")
      File.delete(path)
    end
  end

  describe "namespaced xpath (alvistack/buluma web.xml shape)" do
    it "sets a namespaced element's text with pretty_print" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<?xml version="1.0" encoding="UTF-8"?>\n<web-app xmlns="http://java.sun.com/xml/ns/javaee">\n  <session-config>\n    <session-timeout>60</session-timeout>\n  </session-config>\n</web-app>\n))
      result = run_xml(JSON.parse(%({
        "path": "#{path}",
        "xpath": "/ns:web-app/ns:session-config/ns:session-timeout",
        "namespaces": {"ns": "http://java.sun.com/xml/ns/javaee"},
        "value": "30",
        "pretty_print": "true",
        "state": "present"
      })))
      result["changed"].should be_true
      content = File.read(path)
      content.should contain("<session-timeout>30</session-timeout>")
      content.should contain("encoding='UTF-8'")
      # pretty_print: the output stays multi-line indented
      content.should contain("\n  <session-config>")
      File.delete(path)
    end
  end

  describe "predicate xpath (seraph-config.xml shape)" do
    it "sets text via a [text()='...'] predicate match" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<security-config><parameters><init-param><param-name>autologin.cookie.age</param-name><param-value>1209600</param-value></init-param></parameters></security-config>))
      result = run_xml(xml_params({
        "path"         => path,
        "xpath"        => "/security-config/parameters/init-param[param-name[text()='autologin.cookie.age']]/param-value",
        "value"        => "3600",
        "pretty_print" => "true",
        "state"        => "present",
      }))
      result["changed"].should be_true
      File.read(path).should contain("<param-value>3600</param-value>")
      File.delete(path)
    end
  end

  describe "attributes" do
    it "sets an attribute via the attribute param" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><website><validxhtml/></website></business>))
      result = run_xml(xml_params({
        "path"      => path,
        "xpath"     => "/business/website/validxhtml",
        "attribute" => "validatedon",
        "value"     => "1976-08-05",
      }))
      result["changed"].should be_true
      File.read(path).should contain("validatedon=\"1976-08-05\"")
      File.delete(path)
    end

    it "deletes an attribute via @attr xpath + state absent" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating subjective="true">10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating/@subjective", "state" => "absent"}))
      result["changed"].should be_true
      File.read(path).should contain("</rating>")
      File.read(path).should_not contain("subjective")
      File.delete(path)
    end

    it "creates an empty attribute when only @attr is given" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><website><validxhtml/></website></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/website/validxhtml/@validatedon"}))
      result["changed"].should be_true
      File.read(path).should contain("validatedon=\"\"")
      File.delete(path)
    end
  end

  describe "state: absent element deletion" do
    it "deletes matched elements" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<config><element name="test1"><text>remove</text></element><element name="test2"><text>keep</text></element></config>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/config/element[@name='test1']", "state" => "absent"}))
      result["changed"].should be_true
      content = File.read(path)
      content.should_not contain("test1")
      content.should contain("test2")
      File.delete(path)
    end
  end

  describe "children" do
    it "add_children appends hash and string children" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><beers><beer>Rochefort 10</beer></beers></business>))
      result = run_xml(JSON.parse(%({
        "path": "#{path}",
        "xpath": "/business/beers",
        "add_children": [{"beer": "Old Rasputin"}, "empty_one"],
        "state": "present"
      })))
      result["changed"].should be_true
      content = File.read(path)
      content.should contain("<beer>Old Rasputin</beer>")
      content.should contain("<empty_one/>")
      File.delete(path)
    end

    it "set_children replaces existing children idempotently" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<config><element><text>old</text><text>old2</text></element></config>))
      params = JSON.parse(%({
        "path": "#{path}",
        "xpath": "/config/element",
        "set_children": [{"text": "new"}],
        "state": "present"
      }))
      first = run_xml(params)
      first["changed"].should be_true
      File.read(path).should contain("<text>new</text>")
      second = run_xml(params)
      second["changed"].should be_false
      File.delete(path)
    end
  end

  describe "read-only operations" do
    it "count returns matches without changed" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><beers><beer>a</beer><beer>b</beer></beers></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/beers/beer", "count" => "true"}))
      result["changed"].should be_false
      result["count"].should eq(2)
      File.delete(path)
    end

    it "content: text returns matches as {tag: text}" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<config><element>replaced</element></config>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/config/element", "content" => "text"}))
      result["changed"].should be_false
      result["matches"][0]["element"].should eq("replaced")
      File.delete(path)
    end

    it "content: attribute returns matches as {tag: {attr: val}}" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating subjective="true">10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "content" => "attribute"}))
      result["changed"].should be_false
      result["matches"][0]["rating"]["subjective"].should eq("true")
      File.delete(path)
    end
  end

  describe "pretty_print only (no xpath)" do
    it "reformats a file and is idempotent" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      first = run_xml(xml_params({"path" => path, "pretty_print" => "true"}))
      first["changed"].should be_true
      pretty = File.read(path)
      pretty.should contain("\n  <name>")
      second = run_xml(xml_params({"path" => path, "pretty_print" => "true"}))
      second["changed"].should be_false
      File.delete(path)
    end
  end

  describe "check_mode" do
    it "reports changed without writing" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating>10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "value" => "11", "check_mode" => "true"}))
      result["changed"].should be_true
      File.read(path).should contain("<rating>10</rating>")
      File.delete(path)
    end
  end

  describe "xmlstring mode" do
    it "returns the transformed string instead of writing a file" do
      result = run_xml(xml_params({"xmlstring" => "<a><b>1</b></a>", "xpath" => "/a/b", "value" => "2"}))
      result["changed"].should be_true
      result["xmlstring"].as_s.should contain("<b>2</b>")
    end
  end

  describe "failure modes" do
    it "fails on a missing path" do
      result = run_xml(xml_params({"path" => "/nonexistent/xmlspec_missing.xml", "xpath" => "/a", "value" => "b"}))
      result["failed"].should be_true
      result["msg"].as_s.should contain("does not exist")
    end

    it "fails on malformed XML" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(not < xml))
      result = run_xml(xml_params({"path" => path, "xpath" => "/a", "value" => "b"}))
      result["failed"].should be_true
      result["msg"].as_s.should contain("Error while parsing document")
      File.delete(path)
    end

    it "fails when no action parameter is given" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<a/>))
      result = run_xml(xml_params({"path" => path}))
      result["failed"].should be_true
      File.delete(path)
    end
  end
end
