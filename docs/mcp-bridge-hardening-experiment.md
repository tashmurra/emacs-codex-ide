# Emacs MCP Bridge Hardening Experiment

This branch is a local hardening experiment for the optional Emacs MCP bridge in
`emacs-codex-ide`.

It is intended to explore safer default behavior for users who want Codex to see
some live Emacs context without giving the bridge broad, quiet access to the rest
of their editor state or filesystem. The changes are deliberately scoped to the
bridge, its launcher, generated autoloads, and bridge-focused tests.

## Status

- Branch: `codex/mcp-bridge-policy-gateway`
- Base: `security-hardening` at `7f0db848e81b18297eb2f01ae8bcd5c32fb5d3ca`
- Scope: experimental hardening for review and iteration
- Fork target: `tashmurra/emacs-codex-ide`

This branch is not a security advisory and does not assert that upstream is
unsafe. It is a conservative experiment in secure defaults for a powerful local
integration point. If this work is proposed upstream, it should be presented as a
draft or discussion-oriented contribution so the maintainer can decide whether
the compatibility tradeoffs fit the project.

## Threat Model

The optional MCP bridge lets Codex call Emacs-side tools through a Python MCP
server and `emacsclient`. That is useful, but it also creates a sensitive local
capability boundary:

- Emacs may have many buffers open that are unrelated to the active project.
- File-backed buffers may point outside the project root.
- Symlinks can make paths look project-local while resolving elsewhere.
- TRAMP paths can refer to remote systems.
- The `*Messages*` buffer and active minibuffer can contain tokens, paths,
  prompts, commands, or other private state.
- Debug logs can accidentally persist raw requests or responses on disk.
- Approval auto-exemptions can become too broad if they are keyed only to the
  MCP server name.

The experiment assumes the bridge should remain useful, but should default to a
project-scoped, low-noise posture.

## Central Policy Gateway

`codex-ide-mcp-policy.el` is the single validated catalog for the bridge's 17
tools. Each entry contains the public MCP schema and internal handler, approval,
scope, access, resource, limit, and result-filter policy. Catalog validation
rejects incomplete declarations, duplicate or unknown names, illegal
combinations, malformed schemas, and missing handlers.

The Python MCP process no longer owns a static schema catalog. It fetches the
public catalog from Emacs through `emacsclient`, validates that only `name`,
`description`, and `inputSchema` are present, and caches the result for the
process lifetime. A catalog failure prevents both tool listing and dispatch.
Restart a Codex session to pick up registry changes.

The gateway is the default dispatcher. Before calling a handler it constructs a
short-lived request context, canonicalizes configured roots, resolves every
project resource, and applies the tool's fixed policy. The internal legacy
dispatcher remains available for compatibility comparison and rollback during
the migration window, but it is not exposed as a public option.

Low-risk metadata tools are only auto-eligible when both their fixed registry
classification and `codex-ide-emacs-bridge-auto-approved-tools` allow it.
Content, action, sensitive-state, and unknown tools cannot be promoted by the
user list.

Global metadata remains useful without exposing unrelated identities:

- `emacs_get_all_windows` retains geometry and non-identifying window state but
  returns null buffer/file identities with `scoped: false` outside allowed
  roots.
- `emacs_describe_symbol` redacts out-of-scope definition paths and reports
  `function-file-scoped` and `variable-file-scoped`.
- `emacs_get_all_buffers` omits out-of-scope and sensitive buffers entirely.

Policy decision logging is opt-in:

```emacs-lisp
(setq codex-ide-mcp-bridge-log-policy-decisions t)
```

Events contain only tool name, fixed policy class, allow/deny outcome, and
reason code. Arguments, paths, buffer text, and results are never logged.

## Secure Defaults Added Here

### No default bridge debug log

The Python MCP server no longer writes to `/tmp/codex-ide-mcp-debug.log` by
default.

Debug logging is now opt-in:

```sh
bin/codex-ide-mcp-server.py --debug-log /path/to/log
```

When enabled, the log file is created with mode `0600`. Log entries record event
names and byte counts only. They do not include raw request bodies, response
previews, command vectors, or path-like request content.

### Project-scoped file access

File-oriented bridge tools are constrained to allowed local roots by default.
The session working directory is passed to the Python MCP server as
`--allowed-root`, then forwarded into the Emacs tool-call payload as internal
metadata. It is not exposed as a public MCP tool schema field.

The Emacs side enforces:

- local paths only, with TRAMP paths rejected
- path resolution with `file-truename`
- symlink escape rejection
- outside-root rejection
- directory rejection
- missing-file rejection for tools that open or read files

Root enforcement is unconditional. The old toggle is deprecated as of 0.3.3:

```emacs-lisp
(setq codex-ide-mcp-bridge-allowed-roots nil)
```

`codex-ide-mcp-bridge-enforce-file-roots` remains for one compatibility release.
Setting it to nil emits one warning and is ignored.

`codex-ide-mcp-bridge-allowed-roots` is for explicit additional local roots. The
session working directory is still passed automatically at session startup.

### Bounded buffer text

`emacs_get_buffer_text` now returns bounded text and a `text-truncated` flag.
The default limit matches the existing buffer slice limit:

```emacs-lisp
(setq codex-ide-mcp-bridge-buffer-text-limit
      codex-ide-mcp-bridge-buffer-slice-text-limit)
```

File-backed buffer reads and searches are subject to the same root policy as
file tools.

### Sensitive editor state is opt-in

The bridge no longer exposes `*Messages*` or active minibuffer input by default.

Users who explicitly want those tools can opt in:

```emacs-lisp
(setq codex-ide-mcp-bridge-allow-sensitive-state t)
```

Inactive minibuffer state can still be reported without exposing prompt or input
contents.

### Approval by default

Bridge tool calls now require approval by default:

```emacs-lisp
(setq codex-ide-emacs-bridge-require-approval t)
```

If a user explicitly disables this:

```emacs-lisp
(setq codex-ide-emacs-bridge-require-approval nil)
```

only low-risk metadata tools are eligible for auto-approval:

```emacs-lisp
(setq codex-ide-emacs-bridge-auto-approved-tools
      '("emacs_get_all_buffers"
        "emacs_get_buffer_info"
        "emacs_get_buffer_diagnostics"
        "emacs_get_symbol_at_point"
        "emacs_describe_symbol"
        "emacs_get_all_windows"))
```

Content-bearing, file-opening, search, messages, minibuffer, and buffer-kill
tools are never auto-exempted by this experiment.

### Skill mention paths require cached skills by default

After integrating upstream skill mentions, linked or history-decoded `$skill`
mentions only become structured skill input items when their target path matches
the current session's cached skill list.

Users who explicitly want upstream's broader cold-cache linked-path behavior can
opt in:

```emacs-lisp
(setq codex-ide-mention-allow-uncached-skill-paths t)
```

Mentions selected through completion keep their recorded binding even before a
refreshed skill cache is available.

## Compatibility Notes

These defaults are intentionally stricter than the original bridge behavior.

Users may notice:

- file tools no longer open files outside the session root unless extra roots
  are configured
- symlinked files that resolve outside the root are rejected
- missing files are rejected by open/read tools
- `emacs_get_buffer_text` can return truncated text
- `emacs_get_messages` is disabled unless sensitive state access is opted in
- bridge tool calls prompt for approval unless the user explicitly disables
  approval and the tool is on the metadata allow-list
- linked `$skill` history entries with uncached paths remain visible Markdown
  unless `codex-ide-mention-allow-uncached-skill-paths` is enabled

The compatibility escape hatches are explicit defcustoms rather than preserving
broader access as the default.

## Validation

The branch adds ERT coverage for:

- inside-root file tools
- outside-root rejection
- symlink escape rejection
- TRAMP rejection
- bounded `get_buffer_text` output and truncation reporting
- default-sensitive-state denial
- approval auto-exemption restrictions
- absence of default Python debug logs
- redacted opt-in debug logs
- internal forwarding of `--allowed-root` metadata
- complete and fail-closed policy catalog validation
- catalog fetch, validation, and process-lifetime caching in the Python proxy
- file-backed and non-file project resource authorization
- global window and symbol identity redaction
- generic content-tool denial for Messages and active minibuffer state
- redacted policy decision events
- gateway/legacy response comparison and policy overhead benchmarking
- cached and uncached skill mention path handling

Validated with:

```sh
bin/run-tests.sh --test-file tests/codex-ide-mcp-policy-tests.el --test-file tests/codex-ide-mcp-bridge-tests.el --test-file tests/codex-ide-mcp-tests.el
bin/benchmark-mcp-policy.sh
bin/generate-autoloads.sh
bin/run-tests.sh
bin/pre-commit-check.sh
```

## Upstream Etiquette

If this work is discussed with upstream, the recommended framing is:

- "This is a hardening experiment for the optional MCP bridge."
- "The goal is safer defaults for a powerful local bridge, not a claim that the
  existing project is negligent."
- "The branch intentionally changes defaults, so maintainer feedback on
  compatibility is important."
- "A draft PR or issue discussion is preferable before asking for a merge."
- "Security-sensitive wording should stay factual and avoid overstating risk."

Good next steps before proposing upstream:

- use the branch locally for normal Codex IDE sessions
- note any workflows that become too noisy or constrained
- decide whether stricter defaults should be upstream defaults, fork defaults,
  or optional hardening profile settings
- keep future changes small and isolated to bridge/server/test files

## Maintaining This Fork Branch

To keep this branch current with upstream:

```sh
git fetch origin
git fetch upstream
git switch codex/mcp-bridge-policy-gateway
git rebase upstream/main
bin/run-tests.sh --test-file tests/codex-ide-mcp-policy-tests.el --test-file tests/codex-ide-mcp-bridge-tests.el --test-file tests/codex-ide-mcp-tests.el
bin/run-tests.sh
bin/pre-commit-check.sh
```

If the fork uses `origin`, keep the original repository as `upstream`:

```sh
git remote add upstream https://github.com/dgillis/emacs-codex-ide.git
git remote -v
```
