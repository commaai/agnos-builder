#!/usr/bin/env python3
"""Keep mici modules and optional peripherals after modules_install."""
import argparse
import json
from pathlib import Path
import subprocess

# Onboard devices, service loads, post-root WLAN/BT, and existing interfaces.
# A root can be built in or modular; silently dropping either is a build error.
ROOTS = '''
qcom_q6v5_pas venus_core venus_enc venus_dec spectra_camera fastrpc rpmsg_ctrl
icc_bwmon qcom_stats qcom_wdt coresight_funnel coresight_replicator coresight_stm
coresight_tmc stm_p_basic fuse dm_mod hci_uart btqca cfg80211 mac80211
ath10k_core ath10k_snoc mhi_net cpufreq_powersave cpufreq_conservative qrtr_tun qrtr_mhi
wcd934x snd_soc_wcd934x snd_soc_wsa881x
'''.split()

# Preserve configured optional USB/eGPU, networking, crypto and storage APIs.
# Family selection also accommodates newly configured peripheral drivers.
FAMILIES = (
  'kernel/drivers/usb/', 'kernel/drivers/net/usb/',
  'kernel/drivers/gpu/drm/nouveau/', 'kernel/drivers/gpu/drm/ttm/',
  'kernel/sound/usb/', 'kernel/drivers/bluetooth/', 'kernel/net/bluetooth/',
  'kernel/drivers/bus/mhi/', 'kernel/drivers/net/wwan/',
  'kernel/drivers/net/veth.ko', 'kernel/drivers/net/tun.ko', 'kernel/drivers/net/tap.ko',
  'kernel/drivers/net/macvlan.ko', 'kernel/drivers/net/macvtap.ko', 'kernel/drivers/net/ipvlan/',
  'kernel/drivers/net/ethernet/qualcomm/rmnet/', 'kernel/drivers/net/ipa/',
  'kernel/drivers/gnss/', 'kernel/drivers/md/',
  'kernel/net/netfilter/', 'kernel/net/ipv4/', 'kernel/net/ipv6/', 'kernel/net/can/',
  'kernel/net/bridge/', 'kernel/net/802/', 'kernel/net/8021q/', 'kernel/net/sched/',
  'kernel/crypto/', 'kernel/arch/arm64/crypto/', 'kernel/fs/fuse/',
)


def module_name(path):
  return Path(path).name.removesuffix('.zst').removesuffix('.xz').removesuffix('.gz').removesuffix('.ko').replace('-', '_')


def select_modules(directory, roots=ROOTS, families=FAMILIES):
  dependencies = {}
  for line in (directory / 'modules.dep').read_text().splitlines():
    module, required = line.split(':', 1)
    dependencies[module] = required.split()
  if any(path not in dependencies for required in dependencies.values() for path in required):
    raise ValueError('Installed hard dependency is missing')
  by_name = {module_name(path): path for path in dependencies}
  if len(by_name) != len(dependencies):
    raise ValueError('Duplicate module basename')
  for path in dependencies:
    relative = Path(path)
    if relative.is_absolute() or '..' in relative.parts or not (directory / relative).is_file():
      raise ValueError(f'Invalid installed module: {path}')
  builtins = {module_name(path) for path in (directory / 'modules.builtin').read_text().splitlines()}
  soft = {}
  for line in (directory / 'modules.softdep').read_text().splitlines():
    words = line.split()
    if words and words[0] == 'softdep':
      soft.setdefault(words[1].replace('-', '_'), set()).update(
        name.replace('-', '_') for name in words[2:] if name not in ('pre:', 'post:'))

  pending = set(roots) | {module_name(path) for path in dependencies if path.startswith(families)}
  # USB and HID device drivers also live outside drivers/usb and drivers/hid.
  for line in (directory / 'modules.alias').read_text().splitlines():
    words = line.split()
    if len(words) == 3 and words[0] == 'alias' and words[1].startswith(('usb:', 'hid:')):
      pending.add(words[2])
  keep = set()
  visited = set()
  while pending:
    name = min(pending)
    pending.remove(name)
    name = name.replace('-', '_')
    if name in visited:
      continue
    visited.add(name)
    pending.update(soft.get(name, ()))
    if name in builtins:
      continue
    if name not in by_name:
      raise ValueError(f'Required module is neither installed nor builtin: {name}')
    path = by_name[name]
    if path in keep:
      continue
    keep.add(path)
    pending.update(module_name(required) for required in dependencies[path])
  return keep, set(dependencies) - keep


def package(root, report=None):
  versions = sorted((root / 'lib/modules').iterdir())
  if len(versions) != 1 or not versions[0].is_dir():
    raise ValueError('Expected exactly one installed kernel version')
  directory = versions[0]
  keep, remove = select_modules(directory)
  before = sum(path.stat().st_size for path in directory.rglob('*') if path.is_file())
  order = (directory / 'modules.order').read_text().splitlines()
  uncompressed = {str(Path(path).with_suffix('')) if path.endswith(('.zst', '.xz', '.gz')) else path for path in keep}
  # Validate the complete graph before changing any installed files.
  for path in sorted(remove):
    (directory / path).unlink()
  (directory / 'modules.order').write_text(''.join(path + '\n' for path in order if path in uncompressed))
  for path in sorted(directory.rglob('*'), reverse=True):
    if path.is_dir() and not any(path.iterdir()):
      path.rmdir()
  # Keep full modules.builtin/modinfo; regenerate every modular and builtin index.
  subprocess.run(['depmod', '-b', str(root), directory.name], check=True)
  after = sum(path.stat().st_size for path in directory.rglob('*') if path.is_file())
  result = {'version': directory.name, 'keep': sorted(keep), 'remove': sorted(remove),
            'before_bytes': before, 'after_bytes': after}
  if report:
    report.write_text(json.dumps(result, indent=2) + '\n')
  print(f'{directory.name}: kept {len(keep)} modules, removed {len(remove)}, saved {before - after} bytes')


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('root', type=Path, help='modules_install INSTALL_MOD_PATH; modifies only this build output')
  parser.add_argument('--report', type=Path)
  args = parser.parse_args()
  package(args.root.resolve(), args.report)
