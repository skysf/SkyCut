#!/usr/bin/env python3
"""Verify a real public DMG download against a locally validated release artifact.

Release-time guard, intentionally outside check-all: CI has no local signed DMG,
and a PR must not require its not-yet-published download to exist. Run before
changing a redirect with --url, then again through the stable entry after deploy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


def verify(artifact, url):
    expected_size = artifact.stat().st_size
    with artifact.open('rb') as local:
        expected_hash = hashlib.file_digest(local, 'sha256').hexdigest()
    request = Request(url, headers={'User-Agent': 'SkyCut-Release-Check/1'})
    with urlopen(request, timeout=90) as response:
        if response.status != 200:
            raise ValueError(f'Expected HTTP 200, got {response.status}')
        final_url = response.geturl()
        if urlparse(final_url).hostname != 'downloads.skylu.ai':
            raise ValueError('Download did not resolve to downloads.skylu.ai')
        length = response.headers.get('Content-Length')
        if length is not None and int(length) != expected_size:
            raise ValueError(f'Download size mismatch: expected {expected_size}, got {length}')
        digest = hashlib.sha256()
        count = 0
        while block := response.read(1024 * 1024):
            count += len(block)
            if count > expected_size:
                raise ValueError('Download is larger than the validated local DMG')
            digest.update(block)
    if count != expected_size or digest.hexdigest() != expected_hash:
        raise ValueError(f'Public download differs: bytes {count}/{expected_size}, SHA-256 {digest.hexdigest()} expected {expected_hash}')
    return {'url': final_url, 'bytes': count, 'sha256': expected_hash, 'status': 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--url', default='https://skylu.ai/download/skycut')
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.artifact, args.url)))
    except (OSError, ValueError, HTTPError, URLError) as error:
        print(f'Release download check failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
