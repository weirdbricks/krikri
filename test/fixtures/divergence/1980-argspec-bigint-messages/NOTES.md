# 1980 - a YAML int wider than Int64 printed the marker and the class `str`

- Issue: https://github.com/weirdbricks/krikri/issues/1980
- Found while verifying #1978/#1979.

## What diverged

A YAML integer wider than Int64 travels through krikri as a
`BIGINT_SENTINEL_PREFIX`-marked string (`src/krikri/param_sentinels.cr`). Real
ansible parses it into a Python int, which has no width, so when a *non-int*
argument spec rejects the value the wrapper names the class `int` and prints
the bare digits. krikri's `ArgspecValidator` classified the marked string as a
plain `str` and interpolated the marker into every message:

```
argument 'update_cache' is of type str and we were unable to convert to bool:
The value '<U+E000>bigint:999999999999999999999999' is not a valid boolean.
```

The four tasks pin each message path a marked bigint can reach in the baked
spec table: bool (`apt update_cache`), `str_no_conversion` (`debug var`), the
choices pass (`apt state`) and dict (`uri headers`). Real's own
`convert_bool` output orders the `Valid booleans include:` set by Python's
per-process string hash, so the transcript normalizer sorts it.

## What this case pins

All four tasks. None of them mutates anything: every failure happens in the
argument-spec check itself (verified against pinned ansible-core 2.21.6).
The plugin-side half - podman_container's and docker_compose_v2's private
`int_convertible?` copies, and postgresql's integral-float port - is pinned
in-process by `test/integration/podman_container_test.cr`,
`test/unit/docker_compose_v2_validation_test.cr`,
`test/unit/postgresql_connection_test.cr` and
`test/integration/postgresql_login_port_text_test.cr`.
