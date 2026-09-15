# BUSY Bar upstream references

BreakBar's BUSY Bar adapter follows the official public contracts and client
behavior available when this module was added:

- Device OpenAPI `27.5.0` is the authoritative HTTP contract.
- [`busy-app/busybar-protobuf`](https://github.com/busy-app/busybar-protobuf)
  commit `376ecf7a4bbef7d68451a479398673b0bcc0bfca` is the authoritative state-stream
  wire schema. Its protobuf files are vendored under
  `Sources/BreakBarBusyBar/Protos/` and retain the upstream MIT license in
  `busybar-protobuf.LICENSE.md`.
- [`busy-app/busylib-py`](https://github.com/busy-app/busylib-py) release `2.4.0`
  at commit `88493a3` is the behavioral reference for API-version compatibility,
  request headers, HTTP error categories, and input-event interpretation.

The generated Swift protobuf types are build products. Update the vendored
schemas from a reviewed upstream commit rather than editing generated code.
