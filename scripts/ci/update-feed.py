"""Sign the packaged macOS app and update the rolling Sparkle appcast.

Run after notarization. Downloads the pinned official Sparkle tooling, verifies
the EdDSA key against the public key sealed in the app, signs the archive and
merges one item into the existing appcast fetched from the `appcast` release.
Does not publish anything; the release job uploads the feed.
"""
import argparse
import base64
import hashlib
import io
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

REPOSITORY = 'YJBeetle/OpenScreens'
SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip'
SPARKLE_SHA256 = '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959'
FEED_URL = f'https://github.com/{REPOSITORY}/releases/download/appcast/appcast.xml'
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)
MAX_ITEMS = 40


def q(name):
    return '{' + NAMESPACE + '}' + name


def fetch_existing_feed():
    try:
        with urllib.request.urlopen(FEED_URL, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def sign_update(archive, expected_public_key, secret):
    if len(base64.b64decode(secret, validate=True)) != 32:
        raise ValueError('Expected a 32-byte Sparkle private seed')
    derive = '''import Foundation
import CryptoKit
let input = FileHandle.standardInput.readDataToEndOfFile()
let seed = Data(base64Encoded: String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
'''
    with tempfile.TemporaryDirectory(prefix='openscreens-update-sign-') as temporary:
        root = Path(temporary)
        helper = root / 'derive.swift'
        helper.write_text(derive)
        derived = subprocess.run(
            ['swift', str(helper)], input=secret.encode(), capture_output=True, timeout=180
        )
        if derived.returncode or derived.stdout.decode().strip() != expected_public_key:
            raise RuntimeError('Update private key does not match the public key in the app')

        with urllib.request.urlopen(SPARKLE_URL, timeout=180) as response:
            payload = response.read(48 * 1024 * 1024)
        if hashlib.sha256(payload).hexdigest() != SPARKLE_SHA256:
            raise RuntimeError('Sparkle tool archive checksum mismatch')
        import zipfile
        with zipfile.ZipFile(io.BytesIO(payload)) as bundle:
            tool = root / 'sign_update'
            tool.write_bytes(bundle.read('bin/sign_update'))
        tool.chmod(0o700)

        result = subprocess.run(
            [str(tool), '--ed-key-file', '-', '-p', str(archive)],
            input=secret.encode(), capture_output=True, timeout=180
        )
        if result.returncode:
            raise RuntimeError('Update archive signing failed')
        return result.stdout.decode().strip()


def make_item(channel, info, enclosure, length, signature):
    build = str(info['CFBundleVersion'])
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('CFBundleVersion must be a positive integer')
    marketing = info['CFBundleShortVersionString']
    label = info.get('OpenScreensBuildVersion') or marketing

    if channel == 'stable':
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', marketing):
            raise ValueError('Stable builds need a numeric CFBundleShortVersionString')
        short_version = marketing
        tag = f'v{marketing}'
        title = f'OpenScreens {marketing}'
    else:
        short_version = label if not label.startswith('$(') else marketing
        title = f'OpenScreens {short_version}'

    item = ET.Element('item')
    ET.SubElement(item, 'title').text = title
    ET.SubElement(item, 'link').text = f'https://github.com/{REPOSITORY}/releases/tag/{tag}' if channel == 'stable' else enclosure
    ET.SubElement(item, 'description').text = short_version
    ET.SubElement(item, q('version')).text = build
    ET.SubElement(item, q('shortVersionString')).text = short_version
    ET.SubElement(item, q('minimumSystemVersion')).text = info['LSMinimumSystemVersion']
    if channel != 'stable':
        ET.SubElement(item, q('channel')).text = channel
    ET.SubElement(item, 'enclosure', {
        'url': enclosure,
        'length': str(length),
        'type': 'application/octet-stream',
        q('edSignature'): signature,
    })
    return item


def merge(existing, item):
    if existing:
        root = ET.fromstring(existing)
        channel = root.find('channel')
        if channel is None:
            raise ValueError('Existing appcast has no channel')
    else:
        root = ET.Element('rss', version='2.0')
        channel = ET.SubElement(root, 'channel')
        ET.SubElement(channel, 'title').text = 'OpenScreens'
        ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'

    existing_items = channel.findall('item')
    new_version = item.find(q('version')).text
    new_channel = (item.find(q('channel')).text if item.find(q('channel')) is not None else '')
    kept = []
    for stale in existing_items:
        channel.remove(stale)
        stale_channel = (stale.find(q('channel')).text
                         if stale.find(q('channel')) is not None else '')
        if stale.find(q('version')).text == new_version and stale_channel == new_channel:
            continue
        kept.append(stale)
    channel.append(item)
    channel.extend(kept[:MAX_ITEMS - 1])
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def prepare(app, archive, channel, enclosure, output):
    with open(Path(app) / 'Contents' / 'Info.plist', 'rb') as handle:
        info = plistlib.load(handle)
    public_key = info.get('SUPublicEDKey', '')
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('The app has no valid SUPublicEDKey')
    secret = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
    if not secret:
        print('::warning::SPARKLE_PRIVATE_KEY is not configured; skipping the appcast update')
        return
    signature = sign_update(archive, public_key, secret)
    item = make_item(channel, info, enclosure, Path(archive).stat().st_size, signature)
    feed = merge(fetch_existing_feed(), item)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'appcast.xml').write_bytes(feed)
    print(f'Wrote appcast for {channel} build {info["CFBundleVersion"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--channel', choices=['stable', 'prerelease', 'snapshot'], required=True)
    parser.add_argument('--enclosure-url', required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    try:
        prepare(arguments.app, arguments.archive, arguments.channel,
                arguments.enclosure_url, arguments.output)
    except Exception:
        raise SystemExit('Update feed generation failed; check key configuration, metadata and official tooling.')
