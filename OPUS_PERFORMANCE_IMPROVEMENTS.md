# Performance Improvement Proposal

**Author:** review pass by Opus, 2026-08-05, against `0.9.64`
**Scope:** the engine only — `src/` excluding `src/crystal_play/plugin_helpers/`
and the `plugins/` binaries.

**Status as of `0.9.80`: complete. Nothing in this document is open.**

All twelve items and the "Dead code" section landed across `0.9.66`–`0.9.80`;
`ROADMAP.md` and the commit log carry the measured before/after for each. The
write-ups have been removed rather than left as noise.

The last two to close:

- **Item 5** (`JSON.parse(x.to_json)` as a mutable copy). Its three executor
  sites were converted in `0.9.66`; the fourth, `PluginManager#
  execute_remote_plugin`, disappeared in `0.9.79` when the remote config path
  stopped round-tripping at all. A fifth site that this document never listed
  and that the `0.9.77` review also missed — `crystal-play.cr:47`, in the
  `__async_run` entry point — was found and fixed in `0.9.80`.
- **Item 6** (`VarSubstitutor` rebuilt per task) was carried into
  `OPUS_PERFORMANCE_REVIEW_0.9.77.md` as its item 7 and finished there in
  `0.9.80`.

This file is kept only as a record. For anything still open, see
`OPUS_PERFORMANCE_REVIEW_0.9.77.md`.
