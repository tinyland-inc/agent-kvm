# Validation

Run `npm ci --ignore-scripts` and `npm run test:offline` in the approved remote
Node.js environment. The two credential tests cover framing, native child
launch, password exclusion from arguments, and proxy behavior under failures.
They use a fake native child and do not connect to a real desktop.

`credential-input-cases.py` and `CredentialInputHarness.swift` exercise native
credential input. `../Tests/VNCReconnectTests.swift` covers the Swift VNC
lifecycle and framebuffer readiness. Darwin compilation belongs to the GF/PZM
build lane; `../project.yml` declares its inputs.

The retained `integration.js` and `agents/` files are historical manual live
experiments. They can operate a desktop and consume provider credentials.
They are not invoked by the offline command, and no automatic demo or cloud
provisioning workflow is shipped by this fork. Their existence does not prove
current release acceptance. Use lab's approved PZM acceptance procedure.
