#!/usr/bin/env crystal

require "json"
require "file_utils"
require "krikri-xml"
require "../src/krikri/base_plugin"

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
      action_count = ["add_children", "content", "count", "print_match", "set_children", "value"].count { |prop| raw[prop]? }
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
            next unless node.is_a?(KXML::Element)
            attribs = Hash(String, JSON::Any).new
            node.attributes.each do |attr_node|
              key = attr_node.namespace_uri ? "{#{attr_node.namespace_uri}}#{attr_node.local_name}" : attr_node.name
              attribs[key] = JSON::Any.new(attr_node.value)
            end
            elements << {node.local_name => JSON::Any.new(attribs)}
          end
        end
        matches_result = JSON.parse(elements.to_json)
        msg = elements.size.to_s
      elsif content == "text"
        read_only = true
        elements = [] of Hash(String, JSON::Any)
        if xpath
          match_nodes(doc, xpath).each do |node|
            next unless node.is_a?(KXML::Element)
            elements << {node.local_name => JSON::Any.new(node.text_content)}
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
    @doc : KXML::Document?
    @failed_result : PluginResult?

    private def parse_doc(content : String, source : String) : Nil
      begin
        # krikri-xml parses strictly and raises on every well-formedness
        # violation, matching real lxml's XMLSyntaxError behavior.
        @doc = KXML.parse(content)
      rescue ex : KXML::Error
        @failed_result = PluginResult.new(changed: false, failed: true,
          msg: "Error while parsing document: #{source} (#{ex.message})")
      end
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

    private def match_nodes(doc : KXML::Document, xp : String?) : Array(KXML::Node | KXML::Attribute)
      return [] of (KXML::Node | KXML::Attribute) unless xp
      begin
        result = KXML::XPath.evaluate(xp, doc, ns_map: @namespaces)
        result.is_a?(KXML::XPath::NodeSet) ? result : [] of (KXML::Node | KXML::Attribute)
      rescue KXML::XPath::Error
        [] of (KXML::Node | KXML::Attribute)
      end
    end

    private def node_matches?(doc : KXML::Document, xp : String?) : Bool
      nodes = match_nodes(doc, xp)
      nodes.size > 0 && nodes[0].is_a?(KXML::Element)
    end

    private def each_match(doc : KXML::Document, xp : String?, &) : Nil
      match_nodes(doc, xp).each { |node| yield node }
    end

    private def get_path(node : KXML::Node | KXML::Attribute) : String
      if node.is_a?(KXML::Attribute)
        owner = find_attribute_owner(@doc.not_nil!, node)
        return "" unless owner
        "#{owner.node_path}/@#{node.name}"
      elsif node.is_a?(KXML::Element)
        node.node_path
      else
        ""
      end
    end

    private def find_attribute_owner(doc : KXML::Document, attr : KXML::Attribute) : KXML::Element?
      stack = [doc.as(KXML::Node)]
      until stack.empty?
        n = stack.pop
        if n.is_a?(KXML::Element)
          return n if n.attributes.any? { |a| a.same?(attr) }
        end
        stack.concat(n.children) if n.is_a?(KXML::Element) || n.is_a?(KXML::Document)
      end
      nil
    end

    private def delete_xpath_target(doc : KXML::Document, xp : String?) : Bool
      changed = false
      match_nodes(doc, xp).each do |result|
        changed = true
        if result.is_a?(KXML::Attribute)
          owner = find_attribute_owner(doc, result)
          if owner
            if href = result.namespace_uri
              owner.delete_attribute("{#{href}}#{result.local_name}")
            else
              owner.delete_attribute(result.name)
            end
          end
        else
          result.as(KXML::Node).unlink
        end
      end
      changed
    end

    private def add_target_children(doc : KXML::Document, xp : String?, children : Array(JSON::Any),
                                    input_type : String, insertbefore : Bool, insertafter : Bool) : Bool
      new_kids = children_to_nodes(doc, children, input_type)
      if insertbefore || insertafter
        matches = match_nodes(doc, xp)
        if matches.empty?
          return false
        end
        target = (insertbefore ? matches[0] : matches[-1]).as(KXML::Node)
        parent = target.parent_node
        if parent.nil?
          return false
        end
        new_kids.each do |kid|
          if insertbefore
            target.add_prev_sibling(kid)
          else
            target.add_next_sibling(kid)
          end
        end
      else
        match_nodes(doc, xp).each do |node|
          next unless node.is_a?(KXML::Element)
          new_kids.each do |kid|
            node.append_child(kid)
          end
        end
      end
      true
    end

    private def set_target_children(doc : KXML::Document, xp : String?, children : Array(JSON::Any), input_type : String) : Bool
      return false unless xp
      arr = children
      new_kids = children_to_nodes(doc, arr, input_type)
      changed = false
      match_nodes(doc, xp).each do |match|
        next unless match.is_a?(KXML::Element)
        existing = match.elements
        if existing.size == new_kids.size
          same = existing.each_with_index.all? do |elem, index|
            elem.to_xml == new_kids[index].as(KXML::Node).to_xml
          end
          if same
            next
          end
        end
        existing.each(&.unlink)
        new_kids.each do |kid|
          match.append_child(kid)
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

    private def set_target_inner(doc : KXML::Document, xp : String?, attribute : String?, value : String, create_if_missing : Bool) : Bool
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
        next unless node.is_a?(KXML::Element)
        if attr_clark.nil?
          if node.text_content != value
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

    private def check_or_make_target(doc : KXML::Document, xp : String) : Bool
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
              next unless node.is_a?(KXML::Element)
              if node.text_content != eoa_value
                node.text = eoa_value
                changed = true
              end
            end
          elsif eoa.starts_with?('@')
            attr = eoa[1..]
            attr_clark = attr.includes?(":") ? to_clark(attr) : attr
            match_nodes(doc, inner_xpath).each do |element|
              next unless element.is_a?(KXML::Element)
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

    private def create_and_attach(doc : KXML::Document, inner_xpath : String, name : String, text : String?) : Bool
      changed = false
      match_nodes(doc, inner_xpath).each do |node|
        next unless node.is_a?(KXML::Element)
        node.append_child(new_element(name, text, node))
        changed = true
      end
      changed
    end

    private def new_element(name : String, text : String?, parent : KXML::Element) : KXML::Element
      doc = @doc.not_nil!
      elem = doc.create_element(name, parent, clark_prefix_hint)
      doc.allocate_order(elem)
      if text
        t = doc.create_text(text)
        doc.allocate_order(t)
        elem.append_child(t)
      end
      elem
    end

    @clark_ns_counter = 0

    private def clark_prefix_hint : String
      @clark_ns_counter += 1
      "ns#{@clark_ns_counter}"
    end

    private def children_to_nodes(doc : KXML::Document, children : Array(JSON::Any), input_type : String) : Array(KXML::Node)
      children.map do |child|
        if child.as_s?
          new_element(child.as_s.not_nil!, nil, doc.root.not_nil!)
        elsif h = child.as_h?
          if h.size > 1
            @failed_result = PluginResult.new(changed: false, failed: true,
              msg: "Can only create children from hashes with one key")
            next nil
          end
          key, value = h.first
          if value.as_h?
            sub = value.as_h.not_nil!
            attrs = sub.dup
            children_json = attrs.delete("_")
            child_value = attrs.delete("+value")
            elem = new_element(key, nil, doc.root.not_nil!)
            attrs.each do |attr_name, attr_json|
              set_attr(elem, attr_name, attr_json.as_s? || attr_json.to_s)
            end
            if child_value
              t = doc.create_text(child_value.as_s? || child_value.to_s)
              doc.allocate_order(t)
              elem.append_child(t)
            end
            if children_json
              cj = children_json.as_a?
              cj.try &.each do |subchild|
                children_to_nodes(doc, [subchild], input_type).each do |sub_node|
                  elem.append_child(sub_node)
                end
              end
            end
            elem
          elsif value.as_a?
            @failed_result = PluginResult.new(changed: false, failed: true,
              msg: "Invalid child type: #{value.class}. Children must be either strings or hashes.")
            nil
          else
            new_element(key, value.as_s? || value.to_s, doc.root.not_nil!)
          end
        else
          @failed_result = PluginResult.new(changed: false, failed: true,
            msg: "Invalid child type: #{child.class}. Children must be either strings or hashes.")
          KXML::Element.new("", nil, "", nil, [] of KXML::Attribute)
        end
      end.compact_map { |node| node.as(KXML::Node) unless node.nil? }
    end

    private def to_clark(prefixed : String) : String
      return prefixed unless prefixed.includes?(":")
      prefix, rawname = prefixed.split(":", 2)
      href = @namespaces[prefix]? || ""
      "{#{href}}#{rawname}"
    end

    private def attr_value(element : KXML::Element, name : String) : String?
      element.attribute_value(name)
    end

    private def set_attr(element : KXML::Element, name : String, value : String) : Nil
      element.set_attribute(name, value)
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

    private def serialize(doc : KXML::Document, pretty_print : Bool) : String
      # Real module writes with xml_declaration=True, encoding="UTF-8" via
      # lxml; the declaration is always the normalized single-quote form,
      # followed by a newline only in pretty-print mode (lxml
      # pretty_print=True), and no trailing newline after the root.
      decl = "<?xml version='1.0' encoding='UTF-8'?>"
      body = doc.to_xml(pretty: pretty_print)
      pretty_print ? "#{decl}\n#{body.sub(/\n\z/, "")}" : decl + body
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
