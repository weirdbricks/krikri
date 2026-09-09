require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Round 72000 open-gap regression cover (kostiantyn-nemchenko.patroni): the
# role's own `postgresql_apt_filename: "{{ __postgresql_apt_filename }"`
# default (a genuine missing-brace typo) used to be copied through verbatim
# by the hand-rolled mustache scanner, which found no well-formed `{{ }}`
# span, raised nothing, and let the play run 14 more tasks before failing on
# an unrelated expression - masking the real divergence point. Real
# ansible-core 2.19.4 hard-errors at first use (live-verified): a stray
# single `}` inside the span is "Syntax error in template: unexpected '}'",
# a span with no closer at all is "Syntax error in template: unexpected end
# of template, expected 'end of print statement'."
private def jvars(pairs : Hash(String, String)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  pairs.each { |key, value| result[key] = JSON::Any.new(value) }
  result
end

describe Krikri::VarSubstitutor do
  describe "malformed Jinja2 (unclosed {{ }} span) hard-errors like real Jinja2" do
    it "raises on a stray single closing brace inside the span (the patroni shape)" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"__postgresql_apt_filename" => "pgdg"}))
      expect_raises(Krikri::VariableSubstitutor::TemplateSyntaxError, "Syntax error in template: unexpected '}'") do
        sub.substitute("{{ __postgresql_apt_filename }")
      end
    end

    it "raises on a span with no closing brace anywhere" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"var" => "hello"}))
      expect_raises(Krikri::VariableSubstitutor::TemplateSyntaxError, "unexpected end of template, expected 'end of print statement'.") do
        sub.substitute("prefix {{ var")
      end
    end

    it "still renders a valid dict-literal span whose body contains braces" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"v" => "x"}))
      sub.substitute("{{ {\"a\": 1} }} {{ v }}").should eq "{\"a\":1} x"
    end

    it "leaves a stray closing brace in literal text outside any span verbatim" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"b" => "B"}))
      sub.substitute("a {{ b }} c }").should eq "a B c }"
    end

    it "leaves Go-template brace text from a quoted task-arg literal verbatim" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"helm_install_dir" => "/usr/local/bin"}))
      arg = "{{ helm_install_dir }}/helm version --client --template " \
            "{{ \"'{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'\" }}"
      sub.substitute(arg, strict: true, output: true).should eq \
        "/usr/local/bin/helm version --client --template '{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'"
    end
  end
end
