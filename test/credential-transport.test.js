// SPDX-License-Identifier: MIT
// Prepared offline fixtures. No real daemon, credential, network, or VNC target.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import test from 'node:test';
import { takeCredential, spawnCredentialDaemon } from '../tools/credential-transport.js';

const fakeReceiver = `
  const fs = require('node:fs');
  const crypto = require('node:crypto');
  const frame = fs.readFileSync(3);
  fs.closeSync(3);
  const protocol = fs.readFileSync(0, 'utf8');
  process.stdout.write(JSON.stringify({
    arguments: process.argv.slice(1),
    inheritedPassword: Object.hasOwn(process.env, 'VNC_PASSWORD'),
    length: frame.readUInt32BE(0),
    actualBytes: frame.length - 4,
    digest: crypto.createHash('sha256').update(frame.subarray(4)).digest('hex'),
    protocol
  }));
`;

async function receiver(password) {
  const environment = { VNC_PASSWORD: password };
  const bytes = takeCredential(environment);
  assert.equal(Object.hasOwn(environment, 'VNC_PASSWORD'), false);
  let failures = 0;
  // A second synthetic ambient value proves the spawn sanitizes child env too.
  const child = spawnCredentialDaemon(process.execPath, ['-e', fakeReceiver, '--'], bytes,
    { VNC_PASSWORD: 'synthetic-ambient-must-not-inherit' }, () => { failures++; });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
  child.stdin.end('{"method":"health","id":1}\n');
  const [code, signal] = await once(child, 'close');
  assert.equal(code, 0);
  assert.equal(signal, null);
  assert.equal(stderr, '');
  assert.equal(failures, 0);
  assert.ok(bytes.every((byte) => byte === 0));
  const value = JSON.parse(stdout);
  assert.deepEqual(value.arguments, ['--password-fd', '3']);
  assert.equal(value.inheritedPassword, false);
  assert.equal(value.length, Buffer.byteLength(password, 'utf8'));
  assert.equal(value.actualBytes, value.length);
  assert.equal(value.digest, createHash('sha256').update(password).digest('hex'));
  assert.equal(value.protocol, '{"method":"health","id":1}\n');
}

test('private framed UTF-8 credential leaves protocol stdin intact', { timeout: 10000 }, async () => {
  await receiver('synthetic-ARD-π-\n');
});

test('exact byte limit survives real inherited pipe delivery', { timeout: 10000 }, async () => {
  await receiver('x'.repeat(4096));
});

for (const value of [undefined, '', 'contains\0nul', 'x'.repeat(4097), 'π'.repeat(2049), '\ud800']) {
  test('invalid source credential is consumed and refused before spawn', () => {
    const environment = { VNC_PASSWORD: value };
    assert.throws(() => takeCredential(environment), /credential/i);
    assert.equal(Object.hasOwn(environment, 'VNC_PASSWORD'), false);
  });
}

for (const argument of ['--password', '--password=synthetic', '--password-fd', '--password-fd=0']) {
  test('legacy credential and descriptor override arguments fail before spawn', () => {
    const bytes = takeCredential({ VNC_PASSWORD: 'synthetic-only' });
    assert.throws(() => spawnCredentialDaemon('/nonexistent-owned-fixture', [argument], bytes,
      {}, () => assert.fail('no child may be created')), /cannot be overridden/);
    assert.ok(bytes.every((byte) => byte === 0));
  });
}

test('missing executable closes credential transport with a fixed callback', { timeout: 10000 }, async () => {
  let failures = 0;
  const bytes = takeCredential({ VNC_PASSWORD: 'synthetic-only' });
  const child = spawnCredentialDaemon('/nonexistent-owned-fixture', [], bytes,
    {}, () => { failures++; });
  await new Promise((resolve) => child.once('close', resolve));
  assert.equal(failures, 1);
  assert.ok(bytes.every((byte) => byte === 0));
  assert.ok(child.stdio[3].destroyed);
});
