require "json"

# The bare-ref regex matches simple/dotted/bracketed identifiers
# (with literal keys only - same as REGEX_BARE_VAR_REF spirit).
BARE_REF = /\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:-?\d+|'[^']*'|"[^"]*")\])*)\b/

JINJA_KEYWORDS = Set{
  "if", "elif", "else", "endif", "for", "endfor",
  "set", "endset", "include", "extends", "block",
  "endblock", "macro", "endmacro", "filter", "endfilter",
  "call", "endcall", "in", "is", "not", "and", "or",
  "true", "false", "none", "recursive", "loop", "self",
  "super", "caller", "args", "kwargs", "varargs",
  "true", "false", "none", "and", "or", "not", "in", "is",
  "import", "from", "as", "with", "without",
  "scoped", "endscoped", "autoescape", "endautoescape",
  "raw", "endraw", "filter", "endfilter", "do", "enddo",
  "case", "when", "endcase", "default",
  "applymacro", "endapplymacro",
}

JINJA_FILTERS_BUILTIN = Set{
  "abs", "attr", "batch", "capitalize", "center", "count", "d",
  "default", "dictsort", "e", "escape", "escapejs", "filesizeformat",
  "first", "float", "forceescape", "format", "groupby", "indent",
  "int", "items", "join", "last", "length", "list", "lower",
  "map", "max", "min", "pprint", "random", "reject", "rejectattr",
  "replace", "reverse", "round", "safe", "select", "selectattr",
  "slice", "sort", "string", "striptags", "sum", "title", "tojson",
  "trim", "truncate", "unique", "upper", "urlencode", "urlize",
  "wordcount", "wordwrap", "xmlattr", "as_json", "as_yaml",
  "b64decode", "b64encode", "sha1", "sha256", "md5", "flatten",
  "combine", "items2dict", "dict2items", "to_datetime", "from_json",
  "from_yaml", "to_yaml", "to_nice_yaml", "to_nice_json", "from_csv",
  "regex_search", "regex_findall", "regex_replace", "product",
  "log", "permutations", "combinations", "extract", "type_debug",
  "shuffle", "flatten", "comment", "password_hash", "b32decode",
  "b32encode", "human_readable", "human_to_bytes", "to_bytes",
  "subelements", "start_with", "end_with", "match", "search",
  "ipaddr", "ipwrap", "bool", "checksum", "shorthash", "hash",
  "mandatory", "match_regex", "search_regex",
}

def strip_strings(text : String) : String
  result = text.dup
  loop do
    m = result.match(/(['"])((?:\\.|(?!\1).)*)\1/)
    break unless m
    result = result.sub(m[0], "")
  end
  result
end

def scan_block_refs(cond_no_strings : String, defined_vars : Set(String), issues : Array(String)) : Nil
  cond_no_strings.scan(BARE_REF) do |mat|
    ident = mat[0]
    next if JINJA_KEYWORDS.includes?(ident)
    next if JINJA_FILTERS_BUILTIN.includes?(ident)
    next if defined_vars.includes?(ident)
    # Check if this is a filter invocation (preceded by |)
    idx_in_cond = cond_no_strings.index(ident)
    if idx_in_cond && idx_in_cond > 0 && cond_no_strings[idx_in_cond - 1] == '|'
      next
    end
    issues << ident
  end
end

def find_undefined_in_blocks(text : String, defined_vars : Set(String)) : Array(String)
  issues = [] of String
  i = 0
  while i < text.size
    if i + 1 < text.size && text[i] == '{' && text[i + 1] == '%'
      close = text.index("%}", i + 2)
      break unless close
      inner = text[(i + 2)...close]
      # Extract the condition part (skip "if "/"elif "/"for " prefix)
      cond = inner.strip
      if cond.starts_with?("if ") || cond.starts_with?("elif ")
        cond = cond.sub(/^(if|elif)\s+/, "")
      end
      # Strip string literals to avoid flagging "jre", etc.
      cond_no_strings = strip_strings(cond)
      scan_block_refs(cond_no_strings, defined_vars, issues)
      i = close + 2
    else
      i += 1
    end
  end
  issues
end

vars = Set{"openjdk_install_dir", "openjdk_install_subdir"}

text1 = "{{ openjdk_install_dir }}/{% if openjdk_app == \"jre\" %}-jre{% endif %}suffix"
issues1 = find_undefined_in_blocks(text1, vars)
puts "text1 issues: #{issues1.inspect}"

text2 = "{% if openjdk_app == \"jre\" %}-jre{% endif %}"
issues2 = find_undefined_in_blocks(text2, vars)
puts "text2 issues: #{issues2.inspect}"

text3 = "{% if x is defined and y %}{% endif %}"
vars3 = Set{"x"}
issues3 = find_undefined_in_blocks(text3, vars3)
puts "text3 issues: #{issues3.inspect}"

text4 = "{% for item in items %}{{ item }}{% endfor %}"
vars4 = Set{"items"}
issues4 = find_undefined_in_blocks(text4, vars4)
puts "text4 issues: #{issues4.inspect}"
