#!/usr/bin/env python3
"""Prepared offline native-helper fixtures; no VNC code or real credentials.

Run only in an approved qualification carrier, with the exact compiled harness
hash and an owned scratch directory. This driver is intentionally single-threaded
so its child-only dup2 pre-exec operation has no Python thread/lock interaction.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import time


def framed(value):
    return struct.pack('>I', len(value)) + value


def run_case(binary, scratch, name, payload, expected, transport='pipe', hold_open=False):
    sockets = None
    regular = None
    if transport == 'socket':
        sockets = socket.socketpair()
        read_fd, write_fd = (item.detach() for item in sockets)
    elif transport == 'regular':
        regular = tempfile.TemporaryFile(dir=scratch)
        regular.write(payload)
        regular.flush()
        regular.seek(0)
        read_fd, write_fd = os.dup(regular.fileno()), None
    else:
        read_fd, write_fd = os.pipe()

    child = None
    try:
        # fd3 is explicitly kept across exec, and overwritten in this child
        # with our owned reader. No parent descriptor is repurposed.
        def install_reader():
            if read_fd != 3:
                os.dup2(read_fd, 3)
                os.close(read_fd)

        child = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={}, pass_fds=tuple(sorted({3, read_fd})),
                                 preexec_fn=install_reader)
        os.close(read_fd)
        read_fd = None
        if write_fd is not None:
            os.set_blocking(write_fd, False)
            cursor = 0
            deadline = time.monotonic() + 2
            while cursor < len(payload):
                remaining = deadline - time.monotonic()
                assert remaining > 0, name + ': fixture write deadline'
                _, writable, _ = select.select([], [write_fd], [], remaining)
                assert writable, name + ': fixture write unavailable'
                # Vary write boundaries across the length header and UTF-8 body.
                try:
                    cursor += os.write(write_fd, payload[cursor:cursor + 3])
                except BrokenPipeError:
                    break  # Refusal can close the owned reader before all input.
            if not hold_open:
                os.close(write_fd)
                write_fd = None
        started = time.monotonic()
        try:
            stdout, stderr = child.communicate(b'{"method":"health"}\n', timeout=8)
        except subprocess.TimeoutExpired:
            # Only this unreaped owned fixture child; never a daemon or process
            # selected from a system census. The outer carrier also bounds us.
            child.kill()
            child.communicate(timeout=2)
            raise AssertionError(name + ': native helper exceeded fixture bound')
        elapsed = time.monotonic() - started
        assert len(stdout) < 4096 and stderr == b'', name + ': unexpected output'
        result = json.loads(stdout)
        assert result['credentialDescriptorClosed'] is True, name + ': descriptor left open'
        assert result['accepted'] is (expected == 'accepted'), name + ': result mismatch'
        if expected == 'accepted':
            assert child.returncode == 0 and result['protocolMatches'] is True, name
            assert result['credentialBytes'] == len(payload) - 4, name
            if name in ('valid-pipe', 'valid-socket'):
                assert result['credentialMatches'] is True, name
        else:
            assert child.returncode == 2 and result['category'] == expected, name
        if expected == 'timeout':
            assert elapsed < 7, name + ': deadline not bounded'
        print(json.dumps({'case': name, 'passed': True, 'elapsed_seconds': round(elapsed, 3)}))
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.communicate(timeout=2)
        for fd in (read_fd, write_fd):
            if fd is not None:
                os.close(fd)
        if regular is not None:
            regular.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--harness', required=True, type=Path)
    parser.add_argument('--harness-sha256', required=True)
    parser.add_argument('--scratch', required=True, type=Path)
    args = parser.parse_args()
    assert args.harness.is_absolute() and not args.harness.is_symlink()
    assert hashlib.sha256(args.harness.read_bytes()).hexdigest() == args.harness_sha256
    assert args.scratch.is_absolute() and args.scratch.is_dir() and not args.scratch.is_symlink()
    assert args.scratch.stat().st_uid == os.geteuid()
    value = 'synthetic-ARD-π-\n'.encode()
    cases = [
        ('valid-pipe', framed(value), 'accepted', 'pipe', False),
        ('valid-socket', framed(value), 'accepted', 'socket', False),
        ('maximum', framed(b'x' * 4096), 'accepted', 'pipe', False),
        ('empty-eof', b'', 'frame', 'pipe', False),
        ('truncated-header', b'\0\0', 'frame', 'pipe', False),
        ('truncated-body', framed(value)[:-1], 'frame', 'pipe', False),
        ('empty-password', framed(b''), 'frame', 'pipe', False),
        ('oversized-declaration', struct.pack('>I', 4097), 'frame', 'pipe', False),
        ('oversized-body', framed(b'x' * 4097), 'frame', 'pipe', False),
        ('trailing-byte', framed(value) + b'x', 'frame', 'pipe', False),
        ('invalid-utf8', framed(b'\xff'), 'frame', 'pipe', False),
        ('embedded-nul', framed(b'a\0b'), 'frame', 'pipe', False),
        ('writer-no-frame', b'', 'timeout', 'pipe', True),
        ('writer-no-eof', framed(value), 'timeout', 'socket', True),
        ('regular-file-refused', framed(value), 'custody', 'regular', False),
    ]
    for name, payload, expected, transport, hold in cases:
        run_case(args.harness, args.scratch, name, payload, expected, transport, hold)
    print(json.dumps({'cases_passed': len(cases)}))


if __name__ == '__main__':
    main()
