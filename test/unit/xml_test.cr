require "../minitest_helper"
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
      result["changed"].must_equal(true)
      File.read(path).must_include("<rating>11</rating>")
      File.delete(path)
    end

    it "is idempotent on rerun" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<?xml version="1.0" encoding="UTF-8"?>\n<business><rating>11</rating></business>\n))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "value" => "11"}))
      result["changed"].must_equal(false)
      File.delete(path)
    end

    it "auto-creates missing elements with parent chain" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/website/validxhtml"}))
      result["changed"].must_equal(true)
      content = File.read(path)
      content.must_include("<website>")
      content.must_include("<validxhtml/>")
      File.delete(path)
    end

    it "rejects create_if_missing like real AnsibleModule (live-verified 2026-09-24)" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/missing", "value" => "x", "create_if_missing" => "false"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("Unsupported parameters for (community.general.xml) module: create_if_missing")
      File.read(path).wont_include("missing")
      File.delete(path)
    end

    it "auto-creates a missing xpath target for a value set like real set_target_inner" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/missing", "value" => "x"}))
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["changed"].must_equal(true)
      File.read(path).must_include("<missing>x</missing>")
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
      result["changed"].must_equal(true)
      content = File.read(path)
      content.must_include("<session-timeout>30</session-timeout>")
      content.must_include("encoding='UTF-8'")
      # pretty_print: the output stays multi-line indented
      content.must_include("\n  <session-config>")
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
      result["changed"].must_equal(true)
      File.read(path).must_include("<param-value>3600</param-value>")
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
      result["changed"].must_equal(true)
      File.read(path).must_include("validatedon=\"1976-08-05\"")
      File.delete(path)
    end

    it "deletes an attribute via @attr xpath + state absent" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating subjective="true">10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating/@subjective", "state" => "absent"}))
      result["changed"].must_equal(true)
      File.read(path).must_include("</rating>")
      File.read(path).wont_include("subjective")
      File.delete(path)
    end

    it "creates an empty attribute when only @attr is given" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><website><validxhtml/></website></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/website/validxhtml/@validatedon"}))
      result["changed"].must_equal(true)
      File.read(path).must_include("validatedon=\"\"")
      File.delete(path)
    end
  end

  describe "state: absent element deletion" do
    it "deletes matched elements" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<config><element name="test1"><text>remove</text></element><element name="test2"><text>keep</text></element></config>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/config/element[@name='test1']", "state" => "absent"}))
      result["changed"].must_equal(true)
      content = File.read(path)
      content.wont_include("test1")
      content.must_include("test2")
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
      result["changed"].must_equal(true)
      content = File.read(path)
      content.must_include("<beer>Old Rasputin</beer>")
      content.must_include("<empty_one/>")
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
      first["changed"].must_equal(true)
      File.read(path).must_include("<text>new</text>")
      second = run_xml(params)
      second["changed"].must_equal(false)
      File.delete(path)
    end
  end

  describe "read-only operations" do
    it "count returns matches without changed" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><beers><beer>a</beer><beer>b</beer></beers></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/beers/beer", "count" => "true"}))
      result["changed"].must_equal(false)
      result["count"].must_equal(2)
      File.delete(path)
    end

    it "content: text returns matches as {tag: text}" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<config><element>replaced</element></config>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/config/element", "content" => "text"}))
      result["changed"].must_equal(false)
      result["matches"][0]["element"].must_equal("replaced")
      File.delete(path)
    end

    it "content: attribute returns matches as {tag: {attr: val}}" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating subjective="true">10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "content" => "attribute"}))
      result["changed"].must_equal(false)
      result["matches"][0]["rating"]["subjective"].must_equal("true")
      File.delete(path)
    end
  end

  describe "pretty_print only (no xpath)" do
    it "reformats a file and is idempotent" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><name>co</name></business>))
      first = run_xml(xml_params({"path" => path, "pretty_print" => "true"}))
      first["changed"].must_equal(true)
      pretty = File.read(path)
      pretty.must_include("\n  <name>")
      second = run_xml(xml_params({"path" => path, "pretty_print" => "true"}))
      second["changed"].must_equal(false)
      File.delete(path)
    end
  end

  describe "check_mode" do
    it "reports changed without writing" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<business><rating>10</rating></business>))
      result = run_xml(xml_params({"path" => path, "xpath" => "/business/rating", "value" => "11", "_ansible_check_mode" => "true"}))
      result["changed"].must_equal(true)
      File.read(path).must_include("<rating>10</rating>")
      File.delete(path)
    end
  end

  describe "xmlstring mode" do
    it "returns the transformed string instead of writing a file" do
      result = run_xml(xml_params({"xmlstring" => "<a><b>1</b></a>", "xpath" => "/a/b", "value" => "2"}))
      result["changed"].must_equal(true)
      result["xmlstring"].as_s.must_include("<b>2</b>")
    end
  end

  describe "argument validation (AnsibleModule init order, before any parsing)" do
    it "rejects mutually exclusive action params" do
      result = run_xml(xml_params({"xmlstring" => "<a/>", "xpath" => "/a", "value" => "1", "count" => "true"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("parameters are mutually exclusive")
    end

    it "rejects an invalid content choice" do
      result = run_xml(xml_params({"xmlstring" => "<a/>", "xpath" => "/a", "content" => "bogus"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("value of content must be one of: attribute, text")
    end

    it "rejects an invalid state choice" do
      result = run_xml(xml_params({"xmlstring" => "<a/>", "xpath" => "/a", "state" => "bogus"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("value of state must be one of: absent, present")
    end

    it "rejects a non-boolean value for a bool-typed param" do
      result = run_xml(xml_params({"xmlstring" => "<a><b/></a>", "xpath" => "/a/b", "count" => "krikri_bool"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("is not a valid boolean")
    end

    it "fails when attribute is given without value (required_by)" do
      result = run_xml(xml_params({"xmlstring" => "<a><b/></a>", "xpath" => "/a/b", "attribute" => "x"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("missing parameter(s) required by 'attribute': value")
    end

    it "fails when value is given without xpath (required_by)" do
      result = run_xml(xml_params({"xmlstring" => "<a/>", "value" => "1"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("missing parameter(s) required by 'value': xpath")
    end

    it "fails on unclosed elements (strict parse, no RECOVER)" do
      result = run_xml(xml_params({"xmlstring" => "<root><a>1</root>", "xpath" => "/root/a", "count" => "true"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("Error while parsing document")
    end
  end

  describe "xpath semantics (matching real module)" do
    it "treats add_children on a nonmatching xpath as a silent no-op" do
      result = run_xml(JSON.parse(%({"xmlstring": "<a><b/></a>", "xpath": "/a/nope", "add_children": [{"c": "1"}]})))
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["changed"].must_equal(false)
    end

    it "creates a missing bare-xpath target (no create_if_missing involved)" do
      result = run_xml(xml_params({"xmlstring" => "<a/>", "xpath" => "/a/b"}))
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["changed"].must_equal(true)
      result["xmlstring"].as_s.must_include("<b/>")
    end

    it "reports changed=false for idempotent xmlstring ops (no byte-diff false positive)" do
      result = run_xml(xml_params({"xmlstring" => "<a><b>1</b></a>", "xpath" => "/a/b", "value" => "1"}))
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["changed"].must_equal(false)
    end

    it "print_match is read-only: changed stays false" do
      result = run_xml(xml_params({"xmlstring" => "<a><b>1</b></a>", "xpath" => "/a/b", "print_match" => "true"}))
      expect(falsey?(result["failed"]?)).must_equal(true)
      result["changed"].must_equal(false)
    end

    it "rejects a non-list set_children" do
      result = run_xml(xml_params({"xmlstring" => "<a><b/></a>", "xpath" => "/a/b", "set_children" => "notalist"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("Invalid set_children type: must be a list")
    end
  end

  describe "failure modes" do
    it "fails on a missing path" do
      result = run_xml(xml_params({"path" => "/nonexistent/xmlspec_missing.xml", "xpath" => "/a", "value" => "b"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("does not exist")
    end

    it "fails on malformed XML" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(not < xml))
      result = run_xml(xml_params({"path" => path, "xpath" => "/a", "value" => "b"}))
      result["failed"].must_equal(true)
      result["msg"].as_s.must_include("Error while parsing document")
      File.delete(path)
    end

    it "fails when no action parameter is given" do
      path = File.tempname("xmlspec", ".xml")
      File.write(path, %(<a/>))
      result = run_xml(xml_params({"path" => path}))
      result["failed"].must_equal(true)
      File.delete(path)
    end
  end
end
