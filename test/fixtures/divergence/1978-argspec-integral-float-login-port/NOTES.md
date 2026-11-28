# 1978 - an integral YAML float failed the `type='int'` argument spec

- Issue: https://github.com/weirdbricks/krikri/issues/1978
- Found while verifying #1977.

## What diverged

ansible-core's `check_type_int` is Decimal-based: it converts the value with
`decimal.Decimal` and only fails when the result differs from its own integer
truncation. So a natively-typed integral float converts (`3306.0` -> `3306`)
and only a fractional one fails:

```
argument 'login_port' is of type float and we were unable to convert to int: "1.5" cannot be converted to an int
```

`ArgspecValidator#int_type_error` returned that message for every natively
typed `Float64`, so `login_port: 3306.0` failed the argument spec where real
hands the module the integer.

## What this case pins

- `login_port: -5.0` must reach the module as `-5`. A negative port is
  `getaddrinfo`'s `EAI_SERVICE` and never dials, so real's connection-failure
  wrapper is host independent.
- `login_port: 1.5` must still fail with real's own wording (a significant
  decimal part does not convert).

A dialling integral float (`3306.0`) is left out: its errno depends on what
listens on the truncated port. `test/unit/argspec_validation_test.cr`
covers the conversion itself.
