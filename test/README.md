# Validation

Run the offline proxy tests with Node.js:

```sh
npm ci --ignore-scripts
mkdir -p .test-tmp
TMPDIR="$PWD/.test-tmp" npm run test:offline
```

The scratch directory must be owned by the test user. Fixtures remove their
own files when they finish. The two credential tests cover framing, native child
launch, password exclusion from arguments, and proxy behavior under failures.
They use a fake native child and do not connect to a real desktop.

`credential-input-cases.py` and `CredentialInputHarness.swift` exercise native
credential input. `../Tests/VNCReconnectTests.swift` covers the Swift VNC
lifecycle and framebuffer readiness. [project.yml](../project.yml) declares
the native build inputs.

The retained `integration.js` and `agents/` files are historical manual live
experiments. They can operate a desktop and consume provider credentials.
They are not invoked by the offline command.
