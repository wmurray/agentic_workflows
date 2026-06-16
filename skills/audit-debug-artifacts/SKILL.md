---
name: audit-debug-artifacts
description: Scan changed files for debug artifacts (console.log, binding.pry, debugger, etc.) and report findings grouped by file. Does not modify code.
disable-model-invocation: true
---

# Audit Debug Artifacts

Scan the repo's changed files for likely debug artifacts and report findings grouped by file.

- JS/TS: console.log / console.debug / console.warn / console.error, debugger, alert(
- Ruby/Rails: binding.pry, byebug, debugger, puts, p, pp, ap

Do NOT modify code unless explicitly requested.
