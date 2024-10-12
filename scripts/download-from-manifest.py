#!/usr/bin/env python3
import json
import lzma
import hashlib
import argparse
import http.client
from pathlib import Path
from urllib.parse import urlparse

MASTER_MANIFEST = "https://raw.githubusercontent.com/commaai/openpilot/master/system/hardware/tici/agnos.json"
RELEASE_MANIFEST = "https://raw.githubusercontent.com/commaai/openpilot/release3/system/hardware/tici/agnos.json"

ROOT = Path(__file__).parent.parent

def http_get(url):
  parsed_url = urlparse(url)
  conn = http.client.HTTPSConnection(parsed_url.netloc)
  conn.request("GET", parsed_url.path)
  response = conn.getresponse()
  if response.status != 200:
    raise Exception(f"Failed to download {url}: {response.status} {response.reason}")
  return response

def download_and_decompress(url, expected_hash, filename):
  filename.parent.mkdir(parents=True, exist_ok=True)

  if filename.is_file():
    sha256 = hashlib.sha256()
    with open(filename, 'rb') as f:
      for chunk in iter(lambda: f.read(1024 * 1024), b''):
        sha256.update(chunk)
    if sha256.hexdigest().lower() == expected_hash.lower():
      print(f"Already downloaded: {filename}")
      return 0

  response = http_get(url)
  size = int(response.getheader("Content-Length", 0))

  decompressor = lzma.LZMADecompressor(format=lzma.FORMAT_AUTO)
  sha256 = hashlib.sha256()
  size_counter = 0
  dot_counter = 0

  with open(filename, 'wb') as f:
    while True:
      chunk = response.read(1024 * 1024)
      if not chunk:
        break
      decompressed_chunk = decompressor.decompress(chunk)
      sha256.update(decompressed_chunk)
      f.write(decompressed_chunk)
      size_counter += len(chunk)

      if size_counter // (1024 * 1024) > dot_counter:
        print(f"Downloading '{filename}': {(size_counter * 100) // size}%", end='\r')
        dot_counter += 1

  print(f"Downloading '{filename}': 100%")
  assert sha256.hexdigest().lower() == expected_hash.lower()

def load_manifest(url):
  if Path(url).is_file():
    with open(url) as f:
      return json.loads(f.read())
  response = http_get(url)
  content = response.read().decode()
  return json.loads(content)

if __name__ == "__main__":
  parser = argparse.ArgumentParser(description='Download AGNOS')
  parser.add_argument('--master', action='store_true', help='Download AGNOS version used in the master branch')
  parser.add_argument('--manifest', nargs='?', help='Download AGNOS from the manifest at this URL')
  parser.add_argument('--partitions', nargs='+', default=None, help='Whitelist of partitions to download')

  args = parser.parse_args()
  manifest = RELEASE_MANIFEST if args.manifest is None else args.manifest
  if args.master:
    manifest = MASTER_MANIFEST

  update = load_manifest(manifest)
  for partition in update:
    if args.partitions and partition['name'] not in args.partitions:
      continue
    download_and_decompress(partition['url'], partition['hash'], ROOT / "output" / f"{partition['name']}.img")
