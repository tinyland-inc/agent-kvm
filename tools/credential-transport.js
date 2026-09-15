// SPDX-License-Identifier: MIT
import { spawn } from 'node:child_process';

const MAX_PASSWORD_BYTES = 4096;
const CREDENTIAL_FD = 3;
const DELIVERY_TIMEOUT_MS = 5000;

// The managed launcher supplies this one scoped environment value. Consume it
// before spawning children. Buffer clearing below is not String-memory erasure.
export function takeCredential(environment) {
  const value = environment.VNC_PASSWORD;
  delete environment.VNC_PASSWORD;
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0') ||
      Buffer.byteLength(value, 'utf8') > MAX_PASSWORD_BYTES) {
    throw new Error('A nonempty UTF-8 VNC credential of at most 4096 bytes is required');
  }
  // Reject unpaired UTF-16 surrogates instead of silently changing a password.
  const bytes = Buffer.from(value, 'utf8');
  if (bytes.toString('utf8') !== value) {
    bytes.fill(0);
    throw new Error('VNC credential encoding is invalid');
  }
  return bytes;
}

// fd 0 remains NDJSON. fd 3 carries one length-prefixed credential and EOF.
// No disk file, argv value, or child environment contains the credential.
export function spawnCredentialDaemon(path, args, credential, environment, onFailure) {
  if (!Buffer.isBuffer(credential)) throw new Error('VNC credential buffer is required');
  let frame;
  try {
    if (credential.length === 0 || credential.length > MAX_PASSWORD_BYTES || credential.includes(0)) {
      throw new Error('VNC credential buffer is invalid');
    }
    if (args.some((argument) => argument.startsWith('--password'))) {
      throw new Error('Credential arguments cannot be overridden');
    }
    const childEnvironment = { ...environment };
    delete childEnvironment.VNC_PASSWORD;
    frame = Buffer.alloc(4 + credential.length);
    frame.writeUInt32BE(credential.length, 0);
    credential.copy(frame, 4);
    credential.fill(0);

    const child = spawn(path, [...args, '--password-fd', String(CREDENTIAL_FD)], {
      env: childEnvironment,
      stdio: ['pipe', 'pipe', 'pipe', 'pipe'],
    });
    const channel = child.stdio[CREDENTIAL_FD];
    let finished = false;
    let timer;
    function complete(failed) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      frame.fill(0);
      if (failed) {
        channel.destroy();
        onFailure(); // Caller emits only a fixed diagnostic, never error/argv data.
      }
    }
    channel.once('error', () => complete(true));
    child.once('error', () => complete(true));
    timer = setTimeout(() => complete(true), DELIVERY_TIMEOUT_MS);
    timer.unref();
    channel.end(frame, (error) => complete(Boolean(error)));
    return child;
  } catch (error) {
    credential.fill(0);
    frame?.fill(0);
    throw error;
  }
}
