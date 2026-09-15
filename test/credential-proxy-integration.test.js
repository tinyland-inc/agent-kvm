// SPDX-License-Identifier: MIT
// Exercise the actual MCP entrypoint. The only native child is our owned fake;
// it implements fd3 and PC stdio, imports no networking code and never dials VNC.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { LATEST_PROTOCOL_VERSION } from '@modelcontextprotocol/sdk/types.js';

const entrypoint = fileURLToPath(new URL('../index.js', import.meta.url));
const synthetic = 'offline-ARD-fixture-π-\n';
const syntheticDigest = createHash('sha256').update(synthetic).digest('hex');
const fakeSource = `
const fs = require('node:fs');
const crypto = require('node:crypto');
const readline = require('node:readline');
const marker = process.env.KVM_FIXTURE_MARKER;
const mark = (event) => fs.appendFileSync(marker, JSON.stringify({event, pid:process.pid})+'\\n');
const deadline = setTimeout(() => { mark('fixture-deadline'); process.exit(70); }, 10000);
async function emit(value) {
  await new Promise((resolve, reject) => process.stdout.write(JSON.stringify(value)+'\\n',
    (error) => error ? reject(error) : resolve()));
}
async function main() {
  fs.writeFileSync(marker, JSON.stringify({event:'started',pid:process.pid})+'\\n', {flag:'wx',mode:0o600});
  const chunks=[];let length=0;
  const channel=fs.createReadStream(null,{fd:3,autoClose:true,highWaterMark:512});
  for await (const chunk of channel) {
    length+=chunk.length;
    if(length>4100) throw new Error('invalid fixture frame');
    chunks.push(chunk);
  }
  const frame=Buffer.concat(chunks);
  if(frame.length<5||frame.readUInt32BE(0)!==frame.length-4) throw new Error('invalid fixture frame');
  const credential=frame.subarray(4).toString('utf8');
  const args=process.argv.slice(2);
  const expected=['--host','127.0.0.1','--port','15900','--username','jsullivan2','--password-fd','3'];
  const proof={
    credentialMatches:crypto.createHash('sha256').update(frame.subarray(4)).digest('hex')===process.env.KVM_FIXTURE_EXPECTED_SHA,
    argumentsMatch:JSON.stringify(args)===JSON.stringify(expected),
    credentialInArguments:JSON.stringify(args).includes(credential),
    inheritedPassword:Object.hasOwn(process.env,'VNC_PASSWORD'),
    credentialInEnvironment:Object.values(process.env).some((value)=>value.includes(credential)),
    protocolMethods:[]
  };
  frame.fill(0);
  await emit({method:'ready',params:{scaledWidth:1280,scaledHeight:720}});
  const commands=readline.createInterface({input:process.stdin});
  for await (const line of commands) {
    if(line.length>4096) throw new Error('oversized fixture request');
    const request=JSON.parse(line);
    if(request.method==='health') {
      proof.protocolMethods.push('health');
      await emit({id:request.id,result:{detail:JSON.stringify(proof),scaledWidth:1280,scaledHeight:720}});
    } else if(request.method==='shutdown') {
      mark('shutdown-received');
      if(request.id!==undefined) await emit({id:request.id,result:{detail:'OK'}});
      // Match the pinned native command handler's 100ms response-to-exit delay.
      await new Promise((resolve)=>setTimeout(resolve,100));
      commands.close();
      process.stdin.destroy();
      mark('terminal');
      return;
    } else throw new Error('unexpected fixture protocol method');
  }
  mark('protocol-eof');
}
main().then(()=>{clearTimeout(deadline);process.exit(0);},()=>{
  clearTimeout(deadline);process.stderr.write('fixed fake-native failure\\n');process.exit(70);
});
`;

function newSession(t, overrides = {}) {
  const scratch = process.env.TMPDIR;
  assert.ok(scratch && path.isAbsolute(scratch), 'approved owned TMPDIR is required');
  const parent = fs.lstatSync(scratch);
  assert.ok(parent.isDirectory() && !parent.isSymbolicLink() && parent.uid === process.getuid());
  assert.ok(!/\s/.test(process.execPath), 'fixture shebang requires an unambiguous Node path');
  const directory = fs.mkdtempSync(path.join(scratch, 'kvm-proxy-offline-'));
  fs.chmodSync(directory, 0o700);
  const custody = fs.lstatSync(directory);
  const fake = path.join(directory, 'fake-native.cjs');
  const marker = path.join(directory, 'events.jsonl');
  fs.writeFileSync(fake, `#!${process.execPath}\n${fakeSource}`, { flag: 'wx', mode: 0o700 });
  const environment = {
    CLAUDE_KVM_DAEMON_PATH: fake,
    VNC_HOST: '127.0.0.1', VNC_PORT: '15900', VNC_USERNAME: 'jsullivan2',
    VNC_PASSWORD: synthetic,
    KVM_FIXTURE_MARKER: marker, KVM_FIXTURE_EXPECTED_SHA: syntheticDigest,
    ...overrides,
  };
  for (const key of Object.keys(environment)) {
    if (environment[key] === undefined) delete environment[key];
  }
  const child = spawn(process.execPath, [entrypoint], {
    env: environment, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const closed = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  let stdout = '';
  let stderr = '';
  let inputBuffer = '';
  let nextID = 1;
  const requests = new Map();
  function rejectRequests() {
    for (const pending of requests.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error('owned offline proxy terminated or closed input'));
    }
    requests.clear();
  }
  child.stdin.on('error', rejectRequests);
  child.once('close', rejectRequests);
  child.stdout.setEncoding('utf8').on('data', (chunk) => {
    stdout += chunk;
    inputBuffer += chunk;
    if (stdout.length > 65536) { child.kill('SIGTERM'); return; }
    while (inputBuffer.includes('\n')) {
      const end = inputBuffer.indexOf('\n');
      const line = inputBuffer.slice(0, end);
      inputBuffer = inputBuffer.slice(end + 1);
      let response;
      try { response = JSON.parse(line); } catch { child.kill('SIGTERM'); return; }
      const pending = requests.get(response.id);
      if (pending) { requests.delete(response.id); clearTimeout(pending.timer); pending.resolve(response); }
    }
  });
  child.stderr.setEncoding('utf8').on('data', (chunk) => {
    stderr += chunk;
    if (stderr.length > 65536) child.kill('SIGTERM');
  });
  t.after(async () => {
    // This is our direct unreaped proxy child. Closing it closes all fake-child
    // pipes; the fake additionally has its own ten-second terminal bound.
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await closed;
    for (const pending of requests.values()) clearTimeout(pending.timer);
    const nativeExit = /Daemon exited with code (?:[0-9]+|null)/.test(stderr);
    const beforeSpawnRefusal = !fs.existsSync(marker) &&
      (stderr.includes('A nonempty UTF-8 VNC credential of at most 4096 bytes is required') ||
       stderr.includes('Credential arguments cannot be overridden'));
    assert.ok(nativeExit || beforeSpawnRefusal,
      `native termination is unproved; retain exact fixture for outer carrier cleanup: ${directory}`);
    const current = fs.lstatSync(directory);
    assert.deepEqual([current.dev, current.ino, current.uid], [custody.dev, custody.ino, custody.uid]);
    // Remove exactly these fixture leaves, never a recursive or ambient path.
    for (const leaf of [marker, fake]) {
      if (fs.existsSync(leaf)) fs.unlinkSync(leaf);
    }
    fs.rmdirSync(directory);
  });
  function request(method, params) {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { requests.delete(id); reject(new Error('offline MCP request deadline')); }, 5000);
      requests.set(id, { resolve, reject, timer });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  async function waitForDaemonExit() {
    if (stderr.includes('Daemon exited with code 0')) return;
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.stderr.off('data', onData); reject(new Error('fake daemon exit deadline')); }, 5000);
      const onData = () => {
        if (stderr.includes('Daemon exited with code 0')) {
          clearTimeout(timer); child.stderr.off('data', onData); resolve();
        }
      };
      child.stderr.on('data', onData);
    });
  }
  async function initialize() {
    const response = await request('initialize', {
      protocolVersion: LATEST_PROTOCOL_VERSION, capabilities: {},
      clientInfo: { name: 'owned-offline-fixture', version: '1' },
    });
    assert.ok(response.result && !response.error, 'actual MCP initialization must succeed');
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    const tools = await request('tools/list', {});
    assert.ok(tools.result.tools.some((tool) => tool.name === 'vnc_command'));
  }
  function audit() {
    const forbidden = [synthetic, environment.VNC_PASSWORD, 'synthetic-overlimit-'].filter(Boolean);
    assert.equal(forbidden.some((value) => stdout.includes(value)), false, 'credential leaked to MCP output');
    assert.equal(forbidden.some((value) => stderr.includes(value)), false, 'credential leaked to proxy/native stderr');
    return { stdout, stderr, events: fs.existsSync(marker)
      ? fs.readFileSync(marker, 'utf8').trim().split('\n').map((line) => JSON.parse(line)) : [] };
  }
  return { child, closed, request, initialize, waitForDaemonExit, audit };
}

async function healthy(session) {
  await session.initialize();
  const response = await session.request('tools/call', { name: 'vnc_command', arguments: { action: 'health' } });
  assert.notEqual(response.result.isError, true);
  const proof = JSON.parse(response.result.content.find((item) => item.type === 'text').text);
  assert.deepEqual(proof, {
    credentialMatches: true, argumentsMatch: true, credentialInArguments: false,
    inheritedPassword: false, credentialInEnvironment: false, protocolMethods: ['health'],
  });
  assert.ok(response.result.content.some((item) => item.text === 'display: 1280×720'));
}

test('actual MCP startup, private authentication, health and tool shutdown', { timeout: 15000 }, async (t) => {
  const session = newSession(t);
  await healthy(session);
  const response = await session.request('tools/call', { name: 'vnc_command', arguments: { action: 'shutdown' } });
  assert.equal(response.result.content[0].text, 'OK');
  await session.waitForDaemonExit();
  const after = await session.request('tools/call', { name: 'vnc_command', arguments: { action: 'health' } });
  // Preserve existing lifecycle: shutdown is terminal for this native child,
  // and it never silently creates another executor with another credential.
  assert.equal(after.result.isError, true);
  assert.match(after.result.content[0].text, /Daemon not ready/);
  session.child.kill('SIGINT');
  assert.deepEqual(await session.closed, { code: 0, signal: null });
  assert.deepEqual(session.audit().events.map((event) => event.event), ['started', 'shutdown-received', 'terminal']);
});

test('actual proxy SIGINT requests graceful shutdown of its one native child', { timeout: 15000 }, async (t) => {
  const session = newSession(t);
  await healthy(session);
  session.child.kill('SIGINT');
  assert.deepEqual(await session.closed, { code: 0, signal: null });
  const output = session.audit();
  assert.match(output.stderr, /Daemon exited with code 0/);
  assert.deepEqual(output.events.map((event) => event.event), ['started', 'shutdown-received', 'terminal']);
});

for (const [name, override] of [
  ['missing credential', { VNC_PASSWORD: undefined }],
  ['oversized credential', { VNC_PASSWORD: 'synthetic-overlimit-' + 'x'.repeat(4096) }],
  ['legacy plaintext override', { CLAUDE_KVM_DAEMON_PARAMETERS: '--password synthetic-argument-must-not-log' }],
  ['protocol descriptor override', { CLAUDE_KVM_DAEMON_PARAMETERS: '--password-fd 0' }],
]) {
  test(`actual proxy refuses ${name} before native spawn`, { timeout: 10000 }, async (t) => {
    const session = newSession(t, override);
    const result = await session.closed;
    assert.equal(result.code, 1);
    const output = session.audit();
    assert.deepEqual(output.events, []);
    assert.equal(output.stderr.includes('synthetic-argument-must-not-log'), false);
    assert.equal(output.stdout, '');
  });
}
