# Agent KVM

Remote desktop control over MCP using a native macOS VNC client. Supports
screenshots, mouse and keyboard input, scrolling, and OCR.

## Usage

Install the native daemon and Node.js dependencies (`npm ci --ignore-scripts`),
then configure your MCP client to launch `node index.js` over stdio.

- Set `VNC_HOST` and `VNC_PORT` for the remote VNC server or SSH tunnel.
- Supply `VNC_USERNAME` and `VNC_PASSWORD` through the launch environment.
- Set `CLAUDE_KVM_DAEMON_PATH` if `claude-kvm-daemon` is not on `PATH`.
  Optional native arguments use `CLAUDE_KVM_DAEMON_PARAMETERS`.

The proxy and daemon run on the controlling machine. Existing executable and
environment-variable names remain compatible.

## Development

See [tests](test/README.md), [native build inputs](project.yml), and
[MCP tool schemas](tools/index.js).

Fork of [Claude KVM](https://github.com/ARAS-Workspace/claude-kvm). [MIT license](LICENSE).
