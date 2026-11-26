#!/usr/bin/env python3
"""Verify a real public DMG download against a locally validated release artifact.

Release-time guard, intentionally outside check-all: CI has no local signed DMG,
and a PR must not require its not-yet-published download to exist. Run before
changing a redirect with --url, then again through the stable entry after deploy.
With --feed (after the personal site published skycut.json), it reads the live
update feed the way SkyCut does (no redirect, at most 64 KB) and verifies the DMG
it names: the local artifact's size and SHA-256, its immutable object on
downloads.skylu.ai, HTTP 200 and the full download (docs/architecture/app-updates.md).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen

FEED_URL = 'https://skylu.ai/updates/skycut.json'


def local_digest(artifact):
    with artifact.open('rb') as local:
        return artifact.stat().st_size, hashlib.file_digest(local, 'sha256').hexdigest()


def verify(artifact, url, exact=False):
    expected_size, expected_hash = local_digest(artifact)
    request = Request(url, headers={'User-Agent': 'SkyCut-Release-Check/1'})
    with urlopen(request, timeout=90) as response:
        if response.status != 200:
            raise ValueError(f'Expected HTTP 200, got {response.status}')
        final_url = response.geturl()
        if urlparse(final_url).hostname != 'downloads.skylu.ai':
            raise ValueError('Download did not resolve to downloads.skylu.ai')
        if exact and final_url != url:
            raise ValueError(f'The feed names {url}, which redirects to {final_url}: SkyCut follows no redirect')
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


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError(f'The feed redirects ({code} to {newurl}): SkyCut follows no redirect')


def verify_feed(artifact, feed_url):
    request = Request(feed_url, headers={'User-Agent': 'SkyCut-Release-Check/1', 'Cache-Control': 'no-cache'})
    with build_opener(NoRedirect).open(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError(f'Feed: expected HTTP 200, got {response.status}')
        data = response.read(64 * 1024 + 1)
    if len(data) > 64 * 1024:
        raise ValueError('Feed: larger than 64 KB, SkyCut refuses it')
    feed = json.loads(data)
    size, digest = local_digest(artifact)
    checks = {
        'schema': feed.get('schema') == 1 and not isinstance(feed.get('schema'), bool),
        'bundle_id': feed.get('bundle_id') == 'com.srtflow.SrtFlow',
        'version': isinstance(feed.get('version'), str)
            and re.fullmatch(r'(0|[1-9]\d{0,5})(\.(0|[1-9]\d{0,5})){2}', feed['version']) is not None,
        'dmg_url': isinstance(feed.get('dmg_url'), str) and feed['dmg_url'].startswith('https://downloads.skylu.ai/')
            and feed['dmg_url'].endswith('.dmg'),
        'dmg_size': feed.get('dmg_size') == size,
        'dmg_sha256': feed.get('dmg_sha256') == digest,
        'notes': all(isinstance(feed.get('notes', {}).get(language), list) and feed['notes'][language]
                     for language in ('zh-Hans', 'en', 'es')),
    }
    wrong = [name for name, passed in checks.items() if not passed]
    if wrong:
        raise ValueError(f'Feed: wrong or not this DMG: {", ".join(wrong)}')
    result = verify(artifact, feed['dmg_url'], exact=True)
    result.update({'feed': feed_url, 'version': feed['version']})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--url', default='https://skylu.ai/download/skycut')
    parser.add_argument('--feed', nargs='?', const=FEED_URL, default=None,
                        help=f'verify the live update feed instead (default {FEED_URL})')
    args = parser.parse_args()
    try:
        result = verify_feed(args.artifact, args.feed) if args.feed else verify(args.artifact, args.url)
        print(json.dumps(result))
    except (OSError, ValueError, HTTPError, URLError) as error:
        print(f'Release download check failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
