require "json"

BARE_REF = /\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:-?\d+|'[^']*'|"[^"]*")\])*)\b/

JINJA_KEYWORDS = Set{
  "if", "elif", "else", "endif", "for", "endfor",
  "set", "endset", "include", "extends", "block",
  "endblock", "macro", "endmacro", "filter", "endfilter",
  "call", "endcall", "in", "is", "not", "and", "or",
  "true", "false", "none", "recursive", "loop", "self",
  "super", "caller", "args", "kwargs", "varargs",
  "import", "from", "as", "with", "without",
  "scoped", "endscoped", "autoescape", "endautoescape",
  "raw", "endraw", "do", "enddo",
  "case", "when", "endcase", "default",
  "applymacro", "endapplymacro",
  "defined", "undefined", "none", "divisibleby",
  "even", "odd", "mapping", "sequence", "number",
  "string", "boolean", "true", "false", "integer", "float",
  "iterable", "callable", "sameas", "lower", "upper",
  "eq", "ne", "lt", "le", "gt", "ge", "in",
  "failed", "changed", "succeeded", "success", "skipped", "reachable",
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
  "shuffle", "comment", "password_hash", "b32decode",
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

def parse_block_cond(stripped : String) : {String?, String}?
  if stripped.starts_with?("for ")
    parts = stripped.sub(/^for\s+/, "").split(" in ", 2)
    loop_var = parts[0]?.try(&.strip) if parts
    cond = parts[1]?.try(&.strip) || ""
    {loop_var, cond}
  elsif stripped.starts_with?("set ")
    eq_idx = stripped.index('=')
    if eq_idx
      {stripped[4...eq_idx].strip, stripped[(eq_idx + 1)..].strip}
    else
      {nil, stripped}
    end
  elsif stripped.starts_with?("if ") || stripped.starts_with?("elif ")
    {nil, stripped.sub(/^(if|elif)\s+/, "")}
  else
    nil
  end
end

def scan_block_refs(cond_no_strings : String, loop_var : String?, defined_vars : Set(String), issues : Array(String)) : Nil
  cond_no_strings.scan(BARE_REF) do |mat|
    ident = mat[0]
    next if JINJA_KEYWORDS.includes?(ident)
    next if JINJA_FILTERS_BUILTIN.includes?(ident)
    next if defined_vars.includes?(ident)
    next if loop_var == ident
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
      stripped = inner.strip
      parsed = parse_block_cond(stripped)
      if parsed
        loop_var, cond = parsed
      else
        i = close + 2
        next
      end
      cond_no_strings = strip_strings(cond)
      scan_block_refs(cond_no_strings, loop_var, defined_vars, issues)
      i = close + 2
    else
      i += 1
    end
  end
  issues
end

vars = Set{"openjdk_install_dir", "openjdk_install_subdir", "ssl_protocols", "x", "items"}

tests = [
  ["openjdk case", "{{ openjdk_install_dir }}/{% if openjdk_app == \"jre\" %}-jre{% endif %}suffix"],
  ["double if", "{% if openjdk_app == \"jre\" %}-jre{% endif %}"],
  ["defined test", "{% if x is defined and y %}{% endif %}"],
  ["for loop", "{% for item in items %}{{ item }}{% endfor %}"],
  ["set var", "{% set foo = bar %}{{ foo }}"],
  ["normal defined", "{% if ssl_protocols is defined %}use-{{ ssl_protocols }}{% endif %}"],
  ["ansible test", "{% if result is failed %}{% endif %}"],
  ["nested", "{% if a %}{% if b %}{% endif %}{% endif %}"],
]
tests.each do |tval|
  label = tval[0]
  text = tval[1]
  issues = find_undefined_in_blocks(text, vars.dup)
  puts "%-20s %s -> %s" % [label, text, issues.inspect]
end
