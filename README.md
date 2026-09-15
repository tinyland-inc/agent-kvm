# Agent KVM

Agent KVM is Tinyland's fork of [Claude KVM](https://github.com/ARAS-Workspace/claude-kvm).
It provides remote desktop control over MCP for Codex, Claude Code, and other
compatible clients. The upstream MIT license and author attribution are retained.

## Components

- `index.js` and `tools/` implement the JavaScript MCP proxy.
- `ClaudeKVM-Daemon/` implements the native Swift VNC client.
- `test/` contains proxy and credential-transport tests.
- `Tests/` contains native reconnect, frame-readiness, and diagnostic tests.

The proxy and native client run on the controlling macOS seat. They connect to
the remote machine's VNC server; the native client is not the remote server.

The proxy passes the VNC credential to its native child through a file descriptor,
rather than a password command-line argument. Native recovery is bounded, and a
screenshot requires complete initial framebuffer coverage. Timeout diagnostics
report decoder phase and coverage counters without recording framebuffer data
or credentials.

## Tinyland delivery

The repository's new name is **agent-kvm**. Existing executable names
`claude-kvm` and `claude-kvm-daemon`, configuration variables, and the Apple
signing identifier `dev.tinyland.pzm-computer-use` remain compatibility surfaces.
The repository rename does not rename the npm package or invalidate signed artifacts.

Lab owns Home Manager packages, MCP registry projection, SSH transport, and
workstation activation. Use the lab-managed `pzm-computer-use` entry for PZM.
Its controlling-seat endpoint is `127.0.0.1:15900`, forwarded through native
SSH to PZM's VNC port 5900. Client configuration and credentials come from lab's
managed registry and secret delivery.

GloriousFlywheel owns the broader PZM Darwin artifact build and signing chain
through REAPI. This fork supplies source and tests; it does not establish a
second fleet build controller. The current release procedure signs on PZM and
uses Neo's standalone Command Line Tools for verification and notarization.

## Configuration

| Variable | Purpose |
| --- | --- |
| `VNC_HOST` | VNC server address; Tinyland uses the local SSH tunnel. |
| `VNC_PORT` | VNC port; Tinyland's controlling-seat tunnel uses 15900. |
| `VNC_USERNAME` | Remote account name for Apple Remote Desktop authentication. |
| `VNC_PASSWORD` | Credential supplied by the managed launcher. |
| `CLAUDE_KVM_DAEMON_PATH` | Exact native executable selected by the package. |
| `CLAUDE_KVM_DAEMON_PARAMETERS` | Additional native options, such as display scaling. |

For native options, use the installed daemon's `--help`. Keep credentials out
of repository files, command arguments, logs, and committed MCP configurations.

## MCP interface

The `vnc_command` tool supports screenshots, cursor crops, display differences,
mouse movement and clicks, dragging, scrolling, keyboard input, OCR, runtime
configuration, health queries, and graceful shutdown. Tool schemas in
`tools/index.js` are the interface reference.

Desktop interaction operates the remote user's session. Run live acceptance
only against an authorized target with saved work. Offline tests use fixtures
and do not establish live screen or reboot acceptance.

## Validation and release state

Run `npm run test:offline` in a prepared remote development environment for
the proxy's credential transport tests. Native tests require the declared
Darwin toolchain and dependencies in `project.yml`; use the owning remote
build lane. Neo remains an editing, review, verification, and notarization seat.

The diagnostic native source is `654848c2f6ee9f51d4c37684428c888da90bb883`.
Its recorded native qualification passed 28 tests and a release build. The
signed binary received Apple notarization acceptance in submission
`c0e8b9ee-677c-4903-948b-6b4d75690a5a`. The `1.0.2-tinyland.4` draft contains
that binary and its receipt. Lab package delivery and fresh framebuffer
acceptance remain pending. These results apply to the diagnostic source;
they do not claim validation of this consolidation merge.

Historical demo links and upstream installation instructions are available in
Git history. They are not evidence for Tinyland's current release.
