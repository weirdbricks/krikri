require "crinja"

# Real Jinja2's trim_blocks config only removes a SINGLE newline
# character immediately following a block tag (`{% if x %}\nfoo` ->
# "foo", not "\nfoo") - it does nothing at all when there's no newline
# there to remove.
#
# Crinja::Util::StringTrimmer.trim's own "no newline found in this
# text segment" branch (lib/crinja/src/util/string_trimmer.cr) does
# `first_line.lstrip`, unconditionally stripping *every* leading
# whitespace character - correct for an explicit `{%- ... %}` minus-
# trim (which really does mean "strip all adjacent whitespace"), but
# Renderer.trim_text (lib/crinja/src/runtime/renderer.cr) routes BOTH
# the explicit `-` case AND the implicit trim_blocks-config case
# through that same "left" flag before calling trim(), so trim_blocks
# alone - with no explicit `-` anywhere - also triggers the aggressive
# whole-segment lstrip whenever the text right after a block tag
# happens to have no newline in it (e.g. `{% endif %} {{ x }}`, a
# single literal space with no newline) - silently eating a real,
# meaningful space.
#
# Found benchmarking geerlingguy.solr: solr_default_core_path's own
# default is `{% if ... %}{{ a }}/example/.../conf/{% else %}{{ a
# }}/server/.../conf/{% endif %}`, used as `command: "cp -r {{
# solr_default_core_path }} {{ solr_home }}/data/{{ item }}/"` - the
# space between the two `cp` arguments sat right after `{% endif %}`
# with no newline before the next `{{ }}`, so trim_blocks (CrinjaRenderer
# always sets it, matching real Ansible's own default Jinja2
# environment) ate it, gluing both paths into one argument
# ("cp: missing destination file operand").
#
# Only guards the *implicit* trim_blocks trigger on the text segment
# actually starting with a newline - an explicit `node.trim_left` (real
# `-` syntax) is untouched and still always fully strips, which is
# correct Jinja2 behavior for that case.
class Crinja::Renderer
  def self.trim_text(node, trim_blocks = false, lstrip_blocks = false)
    implicit_trim_blocks = trim_blocks && node.left_is_block && node.string.starts_with?('\n')

    Crinja::Util::StringTrimmer.trim(
      node.string,
      node.trim_left || implicit_trim_blocks,
      node.trim_right || (lstrip_blocks && node.right_is_block),
      node.left_is_block,
      node.right_is_block && lstrip_blocks
    )
  end
end
