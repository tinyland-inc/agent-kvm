#!/usr/bin/env python3
"""Verify carrier-owned OpenSSL input bytes before and after linking.

This is dependency verification, not storage admission before the first write.
Read-only modes do not make files immutable against their owner. The carrier
must preserve exclusive input custody for the complete build and retain both
receipts; this helper holds descriptors only during each verification call.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

EXPECTED = {
    "libssl.a": (1470936, "eaf963fdbd83356365fb4de2dc2eeb586d31948638fc2adf57a3234556d052bf"),
    "libcrypto.a": (8585208, "6e6288edfc69717ab49b490ffc9584fe8f539175ec674ef86c00e1a694f9910f"),
}


class Refusal(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid,
            value.st_mode, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


def verify(directory):
    require(directory != "", "TINYLAND_OPENSSL_LIBRARY_DIR must be supplied explicitly")
    require("\0" not in directory and not any(ord(c) < 32 for c in directory),
            "OpenSSL directory contains control characters")
    path = Path(directory)
    require(path.is_absolute(), "OpenSSL directory must be absolute")
    require(str(path) == directory and path.resolve(strict=True) == path,
            "OpenSSL directory must be canonical, without symlink aliases")
    directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    held = {}
    originals = {}
    try:
        parent = os.fstat(directory_fd)
        require(stat.S_ISDIR(parent.st_mode) and parent.st_mode & 0o222 == 0,
                "OpenSSL directory must be read-only for the build")
        # The declared OpenSSL directory must not offer competing libraries.
        # Xcode can prepend search directories; actual ssl/crypto selection
        # must be checked independently in the qualified linker trace.
        names = set(os.listdir(directory_fd))
        require(set(EXPECTED).issubset(names), "required OpenSSL archive is absent")
        require(not any(name.startswith("lib") and name not in EXPECTED for name in names),
                "unexpected library candidate in OpenSSL input directory")
        result = {}
        for name, (size, expected) in EXPECTED.items():
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory_fd)
            held[name] = descriptor
            before = os.fstat(descriptor)
            originals[name] = identity(before)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                    "OpenSSL archive must be a regular single-link file")
            require(before.st_mode & 0o222 == 0 and before.st_dev == parent.st_dev,
                    "OpenSSL archive must be read-only on the input directory filesystem")
            require(before.st_size == size, "OpenSSL archive size does not match qualified input")
            digest = hashlib.sha256()
            remaining = size
            while remaining:
                data = os.read(descriptor, min(1024 * 1024, remaining))
                require(bool(data), "OpenSSL archive truncated during verification")
                digest.update(data)
                remaining -= len(data)
            require(os.read(descriptor, 1) == b"", "OpenSSL archive grew during verification")
            require(digest.hexdigest() == expected, "OpenSSL archive hash does not match qualified input")
            require(identity(os.fstat(descriptor)) == identity(before),
                    "OpenSSL archive changed during verification")
            require(identity(os.stat(name, dir_fd=directory_fd, follow_symlinks=False)) == identity(before),
                    "OpenSSL archive name changed during verification")
            result[name] = {"sha256": expected, "bytes": size, "device": before.st_dev,
                            "inode": before.st_ino, "uid": before.st_uid,
                            "mode": oct(stat.S_IMODE(before.st_mode))}
        require(set(os.listdir(directory_fd)) == names,
                "OpenSSL directory entries changed during verification")
        require(identity(os.fstat(directory_fd)) == identity(parent) and
                identity(path.lstat()) == identity(parent),
                "OpenSSL directory changed during verification")
        for name, descriptor in held.items():
            require(identity(os.fstat(descriptor)) == originals[name] and
                    identity(os.stat(name, dir_fd=directory_fd, follow_symlinks=False)) == originals[name],
                    "OpenSSL archive binding changed after verification")
        return {"directory": directory, "device": parent.st_dev, "inode": parent.st_ino,
                "archives": result}
    finally:
        for descriptor in held.values():
            os.close(descriptor)
        os.close(directory_fd)


def main():
    require(len(sys.argv) == 3 and sys.argv[2] in ("before-link", "after-link"),
            "usage: verify-openssl-input.py DIRECTORY before-link|after-link")
    result = verify(sys.argv[1])
    result.update(kind="qualified-openssl-input", phase=sys.argv[2],
                  policy="carrier custody with exact hash checks before and after linking")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Refusal as error:
        print("OpenSSL input refused: " + str(error), file=sys.stderr)
        raise SystemExit(1)
    except OSError as error:
        print("OpenSSL input unavailable: errno=" + str(error.errno), file=sys.stderr)
        raise SystemExit(1)
