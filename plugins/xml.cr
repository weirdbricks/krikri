#!/usr/bin/env crystal

require "json"
require "file_utils"
require "xml"
require "../src/krikri/base_plugin"

# libxml2 tree-mutation and path functions Crystal's XML bindings do not
# wrap. `require "xml"` is what links libxml2 itself (the same library
# real community.general.xml uses through lxml on the python side), so
# these declarations only bind functions that are already in the binary.
lib LibXMLTree
  fun xmlAddChild(parent : LibXML::Node*, cur : LibXML::Node*) : LibXML::Node*
  fun xmlAddNextSibling(cur : LibXML::Node*, elem : LibXML::Node*) : LibXML::Node*
  fun xmlAddPrevSibling(cur : LibXML::Node*, elem : LibXML::Node*) : LibXML::Node*
  fun xmlNewDocNode(doc : LibXML::Doc*, ns : Void*, name : UInt8*, content : UInt8*) : LibXML::Node*
  fun xmlNewDocText(doc : LibXML::Doc*, content : UInt8*) : LibXML::Node*
  fun xmlDocCopyNode(node : LibXML::Node*, doc : LibXML::Doc*, extended : Int32) : LibXML::Node*
  fun xmlSearchNsByHref(doc : LibXML::Doc*, node : LibXML::Node*, href : UInt8*) : LibXML::NS*
  fun xmlNewNs(node : LibXML::Node*, href : UInt8*, prefix : UInt8*) : LibXML::NS*
  fun xmlSetNsProp(node : LibXML::Node*, ns : LibXML::NS*, name : UInt8*, value : UInt8*) : LibXML::Node*
  fun xmlUnsetNsProp(node : LibXML::Node*, ns : LibXML::NS*, name : UInt8*) : Int32
  fun xmlGetNodePath(node : LibXML::Node*) : UInt8*
end

module Krikri
  # xml plugin - manages bits and pieces of XML files via xpath. Port of
  # community.general.xml's core semantics (value/attribute set, node
  # auto-creation, delete, add/set_children, count, print_match, content
  # get, pretty_print, insertbefore/after, create_if_missing, backup,
  # check_mode, namespaced xpath + clark-notation attribute names).
  # Real module runs on lxml (also libxml2 underneath), so XPath and
  # serialization behavior match.
  class XmlPlugin < BasePlugin
    def execute : PluginResult
      raw = @config["params"]?.try(&.as_h?) || {} of String => JSON::Any

      path = @params["path"]? || @params["dest"]? || @params["file"]?
      xmlstring = @params["xmlstring"]?
      xpath = @params["xpath"]?
      state = @params["state"]? || @params["ensure"]? || "present"
      attribute = @params["attribute"]?
      content = @params["content"]?
      input_type = @params["input_type"]? || "yaml"
      count = true?(@params["count"]?)
      print_match = true?(@params["print_match"]?)
      pretty_print = true?(@params["pretty_print"]?)
      backup = true?(@params["backup"]?)
      insertbefore = true?(@params["insertbefore"]?)
      insertafter = true?(@params["insertafter"]?)
      create_if_missing = @params["create_if_missing"]? ? true?(@params["create_if_missing"]?) : true

      unless path || xmlstring
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: path, xmlstring")
      end
      unless xpath || content || count || print_match || pretty_print ||
             @params["add_children"]? || @params["set_children"]? || @params["value"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: add_children, content, count, pretty_print, print_match, set_children, value")
      end

      # Real module argument validation (AnsibleModule init), which runs
      # before any XML parsing: mutually exclusive action params, choice
      # enums, and required_by/required_if relationships.
      action_count = ["add_children", "content", "count", "print_match", "set_children", "value"].count { |p| raw[p]? }
      if action_count > 1
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are mutually exclusive: add_children|content|count|print_match|set_children|value")
      end
      if content && content != "attribute" && content != "text"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of content must be one of: attribute, text, got: #{content}")
      end
      if state != "present" && state != "absent"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: absent, present, got: #{state}")
      end
      if input_type != "xml" && input_type != "yaml"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of input_type must be one of: xml, yaml, got: #{input_type}")
      end
      # Real module's required_by treats an explicitly-null value as
      # missing (observed: attribute + `value: null` fails "missing
      # parameter(s) required by 'attribute': value"), so check the raw
      # JSON payload, not just key presence. The engine's param pipeline
      # is Hash(String, String) and collapses a YAML null to an empty
      # string, so treat "" as missing too - the one shape this can't
      # represent is a quoted `value: ""` with attribute:, which real
      # Ansible accepts and sets the attribute to empty.
      value_provided = !raw["value"]?.nil? && !raw["value"].not_nil!.raw.nil? && raw["value"].not_nil!.raw != ""
      if @params["attribute"]? && !value_provided
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'attribute': value")
      end
      if value_provided && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'value': xpath")
      end
      if (content = @params["content"]?) && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'content': xpath")
      end
      if @params["add_children"]? && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'add_children': xpath")
      end
      if @params["set_children"]? && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required by 'set_children': xpath")
      end
      if count && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required if count is True: xpath")
      end
      if print_match && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required if print_match is True: xpath")
      end
      if insertbefore && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required if insertbefore is True: xpath")
      end
      if insertafter && !xpath
        return PluginResult.new(changed: false, failed: true,
          msg: "missing parameter(s) required if insertafter is True: xpath")
      end

      # Real module bool-typed args (type='bool') reject non-boolean
      # strings at AnsibleModule init - live-verified: `count:
      # krikri_bool` fails "The value 'krikri_bool' is not a valid
      # boolean". The engine's param pipeline carries these as strings,
      # so validate before the lenient true?() coercion.
      valid_bools = {"0" => false, "1" => true, "f" => false, "n" => false, "t" => true, "y" => true,
                      "false" => false, "no" => false, "off" => false, "on" => true,
                      "true" => true, "yes" => true}
      {"count", "print_match", "pretty_print", "backup", "insertbefore", "insertafter", "create_if_missing"}.each do |bool_param|
        if (val = @params[bool_param]?) && !valid_bools.has_key?(val.downcase)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{bool_param}' is of type <class 'str'> and we were unable to convert to bool: The value '#{val}' is not a valid boolean.  Valid booleans include: 0, 1, 'f', 'on', 'n', 't', '1', 'false', 'y', 'true', 'off', 'yes', '0', 'no'")
        end
      end

      @namespaces = namespaces_from(raw)
      @doc = nil
      if xmlstring
        parse_doc(xmlstring, xmlstring)
      else
        p = path.not_nil!
        unless File.exists?(p)
          return PluginResult.new(changed: false, failed: true,
            msg: "The target XML source '#{p}' does not exist.")
        end
        unless File::Info.readable?(p)
          return PluginResult.new(changed: false, failed: true,
            msg: "The target XML source '#{p}' is not readable.")
        end
        parse_doc(File.read(p), p)
      end
      if fr = @failed_result
        return fr
      end

      doc = @doc.not_nil!

      # Serialization of the freshly-parsed document with the same options
      # used for output - the "unchanged tree" baseline the real module
      # recomputes from a deepcopy (has_changed).
      orig_serial = serialize(doc, pretty_print)

      matches_result : JSON::Any? = nil
      count_result = nil
      msg = ""
      # The count/print_match/content branches exit before any mutation or
      # write in the real module (finish() with changed=has_changed(tree),
      # which is false for a tree that was only read) - byte differences
      # vs the on-disk file must never turn these into changed=true.
      read_only = false
      # Whether a mutation op ran: finish()-style paths decide changed
      # from the tree mutation alone (has_changed), never from on-disk
      # byte differences; only the pretty_print-only path (make_pretty)
      # compares file bytes.
      op_ran = false

      if print_match
        read_only = true
        list = [] of String
        if xpath
          each_match(doc, xpath) do |node|
            list << get_path(node)
          end
        end
        matches_result = JSON.parse(list.to_json)
        msg = "selector '#{xpath}' match: #{list.to_json}"
      elsif count
        read_only = true
        hits = xpath ? match_nodes(doc, xpath).size : 0
        count_result = hits
        msg = "found #{hits} nodes"
      elsif content == "attribute"
        read_only = true
        elements = [] of Hash(String, JSON::Any)
        if xpath
          match_nodes(doc, xpath).each do |node|
            next unless node.element?
            attribs = Hash(String, JSON::Any).new
            node.attributes.each do |attr_node|
              ns = attr_node.namespace
              key = ns && ns.href ? "{#{ns.href}}#{attr_node.name}" : attr_node.name
              attribs[key] = JSON::Any.new(attr_node.content)
            end
            elements << {node.name => JSON::Any.new(attribs)}
          end
        end
        matches_result = JSON.parse(elements.to_json)
        msg = elements.size.to_s
      elsif content == "text"
        read_only = true
        elements = [] of Hash(String, JSON::Any)
        if xpath
          match_nodes(doc, xpath).each do |node|
            next unless node.element?
            elements << {node.name => JSON::Any.new(node.text)}
          end
        end
        matches_result = JSON.parse(elements.to_json)
        msg = elements.size.to_s
      elsif state == "absent"
        op_ran = true
        delete_xpath_target(doc, xpath)
      elsif set_children_json = raw["set_children"]?
        op_ran = true
        children = normalize_children_json(set_children_json)
        if children.nil?
          return PluginResult.new(changed: false, failed: true,
            msg: "Invalid set_children type: must be a list")
        end
        set_target_children(doc, xpath, children, input_type)
      elsif add_children_json = raw["add_children"]?
        arr = normalize_children_json(add_children_json)
        if arr.nil?
          return PluginResult.new(changed: false, failed: true,
            msg: "Invalid add_children type: must be a list")
        end
        # Real add_target loops over tree.xpath matches - a nonmatching
        # xpath is a silent no-op (changed=false), NOT an error.
        op_ran = true
        add_target_children(doc, xpath, arr, input_type, insertbefore, insertafter)
      elsif value_provided
        op_ran = true
        set_target_inner(doc, xpath, attribute, @params["value"].not_nil!, create_if_missing)
        if @failed_result
          return @failed_result.not_nil!
        end
      elsif xpath
        # Real main()'s ensure_xpath_exists: with no other op, a bare
        # xpath CREATES the missing target - unconditionally, without
        # consulting create_if_missing (that param only gates
        # set_target's value path) - and no-ops when the node exists.
        op_ran = true
        unless node_matches?(doc, xpath)
          check_or_make_target(doc, xpath)
          return @failed_result.not_nil! if @failed_result
        end
      end

      new_serial = serialize(doc, pretty_print)
      tree_changed = new_serial != orig_serial

      if xmlstring
        # Real module computes changed from the mutated-vs-original tree
        # comparison alone (has_changed), never from byte-differences
        # against the xmlstring INPUT - re-serialization always prepends
        # an XML declaration and trailing newline, so a byte comparison
        # would report changed on every read-only or idempotent op.
        # The one byte-comparing path is pretty_print with no xpath
        # (make_pretty: "Modifying a string is not considered a change"
        # does not apply - it explicitly compares and reports changed).
        final_changed = if read_only
          false
        elsif op_ran || xpath
          tree_changed
        elsif pretty_print
          new_serial != xmlstring
        else
          tree_changed
        end
        result = build_result(final_changed, xpath, state, count_result, matches_result, msg)
        result.extra["xmlstring"] = JSON::Any.new(new_serial)
        return result
      end

      p = path.not_nil!
      original_bytes = File.exists?(p) ? File.read(p) : ""
      # Read-only ops never change; mutation ops and the bare-xpath
      # ensure-created path decide from the tree alone (has_changed);
      # only the pretty_print-only path (make_pretty, no xpath - real
      # main() never reaches it when xpath is set) compares file bytes;
      # with no op and no pretty_print there is nothing to do, so
      # changed=false regardless of formatting differences (real module
      # never writes).
      final_changed = if read_only
        false
      elsif op_ran || xpath
        tree_changed
      elsif pretty_print
        new_serial != original_bytes
      else
        false
      end
      backup_file = ""
      if final_changed && !check_mode?
        if backup && File.exists?(p)
          backup_file = write_backup(p)
        end
        write_new_content(p, new_serial)
      end

      diff = generate_unified_diff(original_bytes, new_serial, p, p) if final_changed && diff_mode?
      result = build_result(final_changed, xpath, state, count_result, matches_result, msg)
      result.diff = diff if diff
      result.extra["backup_file"] = JSON::Any.new(backup_file) if backup_file != ""
      result
    end

    @namespaces : Hash(String, String) = {} of String => String
    @doc : XML::Document?
    @failed_result : PluginResult?

    private def parse_doc(content : String, source : String) : Nil
      begin
        # Strict parse: Crystal's ParserOptions.default includes RECOVER,
        # which silently auto-closes unclosed elements / drops junk -
        # real lxml (this module's parser) raises XMLSyntaxError on all
        # of it. Drop RECOVER, keep NOWARNING/NONET.
        @doc = XML.parse(content, XML::ParserOptions.flags(NOWARNING, NONET))
      rescue ex : XML::Error
        @failed_result = PluginResult.new(changed: false, failed: true,
          msg: "Error while parsing document: #{source} (#{ex.message})")
      end
      # Crystal's XML.parse silently drops junk around the root element
      # (real lxml raises XMLSyntaxError); a parsed document with no root
      # element is the tell.
      if @failed_result.nil? && @doc.try(&.root).nil?
        @failed_result = PluginResult.new(changed: false, failed: true,
          msg: "Error while parsing document: #{source}")
      end
    end

    private def namespaces_from(raw : Hash(String, JSON::Any)) : Hash(String, String)
      ns = {} of String => String
      if nsv = raw["namespaces"]?
        if h = nsv.as_h?
          h.each do |k, v|
            ns[k] = v.as_s? || v.to_s
          end
        elsif s = nsv.as_s?
          # Templated dict params arrive as their string form - valid JSON
          # only. A whole-value `{{ dict_var }}` container arg arrives as
          # the double-quoted JSON the wire serialized it to (see
          # substitute_task_params's whole-single-span comment); NEVER a
          # Python-repr repair pass - a value that merely LOOKS like a
          # container is a plain STRING in real ansible-core
          # (live-verified vs ansible-playbook 2.19.11, see apt.cr's
          # parse_package_names).
          parsed = begin
            JSON.parse(s).as_h?
          rescue
            nil
          end
          parsed.try &.each do |k, v|
            ns[k] = v.as_s? || v.to_s
          end
        end
      end
      ns
    end

    private def match_nodes(doc : XML::Document, xp : String?) : Array(XML::Node)
      return [] of XML::Node unless xp
      begin
        result = doc.xpath(xp, @namespaces)
        case result
        when XML::NodeSet then result.to_a
        else                   [] of XML::Node
        end
      rescue XML::Error
        [] of XML::Node
      end
    end

    private def node_matches?(doc : XML::Document, xp : String?) : Bool
      nodes = match_nodes(doc, xp)
      nodes.size > 0 && nodes[0].element?
    end

    private def each_match(doc : XML::Document, xp : String?, &) : Nil
      match_nodes(doc, xp).each { |node| yield node }
    end

    private def get_path(node : XML::Node) : String
      cstr = LibXMLTree.xmlGetNodePath(node.to_unsafe)
      s = cstr.null? ? "" : String.new(cstr)
      s
    end

    private def delete_xpath_target(doc : XML::Document, xp : String?) : Bool
      changed = false
      match_nodes(doc, xp).each do |result|
        changed = true
        if result.type == XML::Node::Type::ATTRIBUTE_NODE
          parent = result.parent
          unset_attr(parent.not_nil!, result.name) if parent
        else
          result.unlink
        end
      end
      changed
    end

    private def add_target_children(doc : XML::Document, xp : String?, children : Array(JSON::Any),
                                    input_type : String, insertbefore : Bool, insertafter : Bool) : Bool
      new_kids = children_to_nodes(doc, children, input_type)
      if insertbefore || insertafter
        matches = match_nodes(doc, xp)
        if matches.empty?
          return false
        end
        target = insertbefore ? matches[0] : matches[-1]
        parent = target.parent
        if parent.nil?
          return false
        end
        new_kids.each do |kid|
          if insertbefore
            LibXMLTree.xmlAddPrevSibling(target.to_unsafe, kid)
          else
            LibXMLTree.xmlAddNextSibling(target.to_unsafe, kid)
          end
        end
      else
        match_nodes(doc, xp).each do |node|
          new_kids.each do |kid|
            LibXMLTree.xmlAddChild(node.to_unsafe, kid)
          end
        end
      end
      true
    end

    private def set_target_children(doc : XML::Document, xp : String?, children : Array(JSON::Any), input_type : String) : Bool
      return false unless xp
      arr = children
      new_kids = children_to_nodes(doc, arr, input_type)
      changed = false
      match_nodes(doc, xp).each do |match|
        existing = [] of XML::Node
        match.children.each { |child| existing << child if child.element? }
        if existing.size == new_kids.size
          same = existing.each_with_index.all? do |elem, index|
            elem.to_xml(options: XML::SaveOptions::AS_XML) == wrap_node(doc, new_kids[index]).to_xml(options: XML::SaveOptions::AS_XML)
          end
          if same
            next
          end
        end
        existing.each(&.unlink)
        new_kids.each do |kid|
          LibXMLTree.xmlAddChild(match.to_unsafe, kid)
        end
        changed = true
      end
      changed
    end

    # The engine's param pipeline stringifies YAML list params (a
    # list-of-dicts arrives as JSON text - see playbook_parser's
    # stringify_value), so a children param may be a real JSON array OR
    # a JSON-encoded string of one.
    private def normalize_children_json(node : JSON::Any) : Array(JSON::Any)?
      if arr = node.as_a?
        return arr
      end
      if str = node.as_s?
        begin
          return JSON.parse(str).as_a?
        rescue JSON::ParseException
          return nil
        end
      end
      nil
    end

    private def wrap_node(doc : XML::Document, ptr : LibXML::Node*) : XML::Node
      XML::Node.new(ptr, doc)
    end

    private def set_target_inner(doc : XML::Document, xp : String?, attribute : String?, value : String, create_if_missing : Bool) : Bool
      return false unless xp
      if !node_matches?(doc, xp)
        if !create_if_missing
          return false
        end
        check_or_make_target(doc, xp)
        if @failed_result
          return false
        end
      end

      if !node_matches?(doc, xp)
        @failed_result = PluginResult.new(changed: false, failed: true,
          msg: "Xpath #{xp} does not reference a node!")
        return false
      end

      changed = false
      attr_clark = attribute ? (attribute.includes?(":") ? to_clark(attribute) : attribute) : nil
      match_nodes(doc, xp).each do |node|
        next unless node.element?
        if attr_clark.nil?
          if node.text != value
            node.text = value
            changed = true
          end
        else
          if attr_value(node, attr_clark) != value
            set_attr(node, attr_clark, value)
            changed = true
          end
        end
      end
      changed
    end

    private def check_or_make_target(doc : XML::Document, xp : String) : Bool
      inner_xpath, changes = split_xpath_last(xp)
      if inner_xpath == xp || changes.empty?
        @failed_result = PluginResult.new(changed: false, failed: true,
          msg: "Can't process Xpath #{xp} in order to spawn nodes!")
        return false
      end

      changed = false

      if !node_matches?(doc, inner_xpath)
        changed = check_or_make_target(doc, inner_xpath)
        if @failed_result
          return false
        end
      end

      if node_matches?(doc, inner_xpath)
        changes.each do |change|
          eoa = change[:eoa]
          eoa_value = change[:value]
          if !eoa.empty? && !eoa.starts_with?('@') && !eoa.starts_with?('/')
            name = eoa.includes?(":") ? to_clark(eoa) : eoa
            changed_here = create_and_attach(doc, inner_xpath, name, eoa_value)
            changed ||= changed_here
          elsif eoa.empty?
            next if eoa_value.nil?
            match_nodes(doc, inner_xpath).each do |node|
              if node.text != eoa_value
                node.text = eoa_value
                changed = true
              end
            end
          elsif eoa.starts_with?('@')
            attr = eoa[1..]
            attr_clark = attr.includes?(":") ? to_clark(attr) : attr
            match_nodes(doc, inner_xpath).each do |element|
              next unless element.element?
              current = attr_value(element, attr_clark)
              if current.nil? || current != eoa_value
                set_attr(element, attr_clark, eoa_value || "")
                changed = true
              end
            end
          end
        end
      end

      changed
    end

    private def create_and_attach(doc : XML::Document, inner_xpath : String, name : String, text : String?) : Bool
      changed = false
      match_nodes(doc, inner_xpath).each do |node|
        ptr = new_element_ptr(name, text, node)
        LibXMLTree.xmlAddChild(node.to_unsafe, ptr)
        changed = true
      end
      changed
    end

    private def new_element_ptr(name : String, text : String?, parent : XML::Node) : LibXML::Node*
      doc_ptr = @doc.not_nil!.to_unsafe.as(LibXML::Doc*)
      href, local = parse_clark(name)
      if href
        ptr = LibXMLTree.xmlNewDocNode(doc_ptr, nil, local, nil)
        nsptr = LibXMLTree.xmlSearchNsByHref(doc_ptr, parent.to_unsafe, href)
        if nsptr.null?
          nsptr = LibXMLTree.xmlNewNs(ptr, href, clark_prefix_hint)
        end
        ptr.value.ns = nsptr
      else
        ptr = LibXMLTree.xmlNewDocNode(doc_ptr, nil, local, nil)
      end
      if text
        tptr = LibXMLTree.xmlNewDocText(doc_ptr, text)
        LibXMLTree.xmlAddChild(ptr, tptr)
      end
      ptr
    end

    @clark_ns_counter = 0

    private def clark_prefix_hint : String
      @clark_ns_counter += 1
      "ns#{@clark_ns_counter}"
    end

    private def children_to_nodes(doc : XML::Document, children : Array(JSON::Any), input_type : String) : Array(LibXML::Node*)
      children.map do |child|
        if child.as_s?
          new_element_ptr(child.as_s.not_nil!, nil, doc.root.not_nil!)
        elsif h = child.as_h?
          if h.size > 1
            @failed_result = PluginResult.new(changed: false, failed: true,
              msg: "Can only create children from hashes with one key")
            next nil.as(LibXML::Node*)
          end
          key, value = h.first
          if value.as_h?
            sub = value.as_h.not_nil!
            attrs = sub.dup
            children_json = attrs.delete("_")
            child_value = attrs.delete("+value")
            ptr = new_element_ptr(key, nil, doc.root.not_nil!)
            attrs.each do |attr_name, attr_json|
              set_attr(wrap_node(doc, ptr), attr_name, attr_json.as_s? || attr_json.to_s)
            end
            if child_value
              tptr = LibXMLTree.xmlNewDocText(doc.to_unsafe.as(LibXML::Doc*), child_value.as_s? || child_value.to_s)
              LibXMLTree.xmlAddChild(ptr, tptr)
            end
            if children_json
              cj = children_json.as_a?
              cj.try &.each do |subchild|
                sub_ptr = children_to_nodes(doc, [subchild], input_type)
                sub_ptr.each do |sub_node|
                  LibXMLTree.xmlAddChild(ptr, sub_node)
                end
              end
            end
            ptr
          elsif value.as_a?
            @failed_result = PluginResult.new(changed: false, failed: true,
              msg: "Invalid child type: #{value.class}. Children must be either strings or hashes.")
            nil.as(LibXML::Node*)
          else
            new_element_ptr(key, value.as_s? || value.to_s, doc.root.not_nil!)
          end
        else
          @failed_result = PluginResult.new(changed: false, failed: true,
            msg: "Invalid child type: #{child.class}. Children must be either strings or hashes.")
          nil.as(LibXML::Node*)
        end
      end.reject Nil
    end

    private def to_clark(prefixed : String) : String
      return prefixed unless prefixed.includes?(":")
      prefix, rawname = prefixed.split(":", 2)
      href = @namespaces[prefix]? || ""
      "{#{href}}#{rawname}"
    end

    private def parse_clark(name : String) : {String?, String}
      if name.starts_with?('{') && (i = name.index('}'))
        {name[1...i], name[(i + 1)..]}
      else
        {nil, name}
      end
    end

    private def attr_value(element : XML::Node, name : String) : String?
      href, local = parse_clark(name)
      if href
        element.attributes.each do |attr_node|
          ns = attr_node.namespace
          return attr_node.content if attr_node.name == local && ns && ns.href == href
        end
        nil
      else
        element[local]?
      end
    end

    private def set_attr(element : XML::Node, name : String, value : String) : Nil
      href, local = parse_clark(name)
      if href
        doc_ptr = @doc.not_nil!.to_unsafe.as(LibXML::Doc*)
        nsptr = LibXMLTree.xmlSearchNsByHref(doc_ptr, element.to_unsafe, href)
        if nsptr.null?
          nsptr = LibXMLTree.xmlNewNs(element.to_unsafe, href, clark_prefix_hint)
        end
        LibXMLTree.xmlSetNsProp(element.to_unsafe, nsptr, local, value)
      else
        element[local] = value
      end
    end

    private def unset_attr(element : XML::Node, name : String) : Nil
      href, local = parse_clark(name)
      if href
        doc_ptr = @doc.not_nil!.to_unsafe.as(LibXML::Doc*)
        nsptr = LibXMLTree.xmlSearchNsByHref(doc_ptr, element.to_unsafe, href)
        unless nsptr.null?
          LibXMLTree.xmlUnsetNsProp(element.to_unsafe, nsptr, local)
        end
      else
        element.delete(local)
      end
    end

    # split_xpath_last - the real module's regex cascade for turning an
    # XPath with a simple "last step" into (parent path, change spec),
    # used only by the node auto-creation path.
    IDENT               = "[a-zA-Z-][a-zA-Z0-9_\\-\\.]*"
    NSIDENT             = "(?:#{IDENT}|#{IDENT}:#{IDENT})"
    XPSTR               = "('(?:.*)'|\"(?:.*)\")"
    RE_SIMPLE_LAST      = /^(.*)\/(#{NSIDENT})$/
    RE_SIMPLE_LAST_EQ   = /^(.*)\/(#{NSIDENT})\/text\(\)=#{XPSTR}$/
    RE_SIMPLE_ATTR_LAST = /^(.*)\/(@#{NSIDENT})$/
    RE_SIMPLE_ATTR_EQ   = /^(.*)\/(@#{NSIDENT})=#{XPSTR}$/
    RE_SUB_LAST         = /^(.*)\/(#{NSIDENT})\[(.*)\]$/
    RE_ONLY_EQ          = /^(.*)\/text\(\)=#{XPSTR}$/

    alias XpathChange = {eoa: String, value: String?}
    alias XpathSplit = {String, Array(XpathChange)}

    private def split_xpath_last(xp : String) : XpathSplit
      xp = xp.strip
      if m = xp.match(RE_SIMPLE_LAST)
        return {m[1], [{eoa: m[2], value: nil.as(String?)}]}
      end
      if m = xp.match(RE_SIMPLE_LAST_EQ)
        return {m[1], [{eoa: m[2], value: extract_xpstr(m[3]).as(String?)}]}
      end
      if m = xp.match(RE_SIMPLE_ATTR_LAST)
        return {m[1], [{eoa: m[2], value: nil.as(String?)}]}
      end
      if m = xp.match(RE_SIMPLE_ATTR_EQ)
        return {m[1], [{eoa: m[2], value: extract_xpstr(m[3]).as(String?)}]}
      end
      if m = xp.match(RE_SUB_LAST)
        content = m[3].split(" and ").map(&.strip)
        return {m[1], [{eoa: "/#{m[2]}", value: content.join(" and ").as(String?)}]}
      end
      if m = xp.match(RE_ONLY_EQ)
        return {m[1], [{eoa: "", value: extract_xpstr(m[2]).as(String?)}]}
      end
      {xp, [] of XpathChange}
    end

    private def extract_xpstr(s : String) : String
      s[1..-2]
    end

    private def serialize(doc : XML::Document, pretty_print : Bool) : String
      options = pretty_print ? XML::SaveOptions::FORMAT | XML::SaveOptions::AS_XML : XML::SaveOptions::AS_XML
      s = doc.to_xml(indent: 2, options: options)
      # Real module writes with xml_declaration=True, encoding="UTF-8" via
      # lxml; libxml2 only emits the encoding attribute when the source
      # document declared one. Normalize the declaration to match.
      s = s.sub("<?xml version=\"1.0\"?>", "<?xml version='1.0' encoding='UTF-8'?>")
      s = s.sub("<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<?xml version='1.0' encoding='UTF-8'?>")
      s
    end

    private def build_result(changed : Bool, xp : String?, state : String,
                             count_result : Int32?, matches_result : JSON::Any?,
                             msg : String) : PluginResult
      namespaces = Hash(String, JSON::Any).new
      @namespaces.each { |k, v| namespaces[k] = JSON::Any.new(v) }
      actions = {
        "xpath"      => xp.nil? ? JSON::Any.new("") : JSON::Any.new(xp),
        "namespaces" => JSON::Any.new(namespaces),
        "state"      => JSON::Any.new(state),
      }
      result = PluginResult.new(changed: changed, failed: false, msg: msg)
      result.extra["actions"] = JSON::Any.new(actions)
      result.extra["count"] = JSON::Any.new(count_result) if count_result
      result.extra["matches"] = matches_result if matches_result
      result
    end

    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    private def write_new_content(path : String, content : String) : Nil
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path, content)
    end

    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::XmlPlugin.new(config)
plugin.run
