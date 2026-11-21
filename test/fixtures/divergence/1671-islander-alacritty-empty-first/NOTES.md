# 1671 - islander.alacritty: `first` on an empty `json_query` result

- Issue: https://github.com/weirdbricks/krikri/issues/1671
- Role: `islander.alacritty` (round29920618, ubuntu)
- Divergence: real ansible fails "Parse alacritty deb url" with
  `No first item, sequence was empty.`, while krikri succeeded and carried an
  empty string into the later `get_url` task.

## Why

`json_query(query)` is a filter whose argument Jinja evaluates first, so the
filter receives the JMESPath TEXT the `query` var holds. krikri's hand-rolled
fallback engine passed the bare variable NAME through as the expression
instead, looking up a field called `query`, getting null, and silently
succeeding where ansible's empty match makes `first` fail the task.

The role's `uri` fetch of GitHub's latest release is replaced by a static
`alacritty_latest` with no `amd64.deb` asset: that is exactly the release shape
(`v0.17.0`) the round hit, without depending on the network or on GitHub's
current release contents.
