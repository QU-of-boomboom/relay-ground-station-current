"""Explicit reversible UIO binding for the verified FMQL ground station window.

No boot files, clock controls, shared resets or register values are written.
Run as root, with the verified dtbo beside this script. No auto-start installed.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat

OVERLAY = Path('/sys/kernel/config/device-tree/overlays/relay-groundstation')
DEVICE = Path('/sys/bus/platform/devices/400c1000.relay-groundstation')
DRIVER = Path('/sys/bus/platform/drivers/uio_pdrv_genirq')
DT = Path('/sys/firmware/devicetree/base/amba-apu@0')
DTBO_SHA = '85f4e05ef546f441db805ab9e030ff455d06cb8d22ff43ec39ba3b45e9f3f7ae'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_parent():
    for name, expected in [('#address-cells', '00000001'), ('#size-cells', '00000001'),
                           ('ranges', '000000000000000000000000ffffffff')]:
        require((DT/name).read_bytes().hex() == expected, 'Parent DT changed: '+name)


def status():
    require(OVERLAY.is_dir() and (OVERLAY/'status').read_text().strip() == 'applied', 'Overlay not applied')
    require((DEVICE/'of_node/reg').read_bytes().hex() == '400c100000001000', 'Wrong DT register region')
    require((DEVICE/'driver').resolve() == DRIVER.resolve(), 'Wrong driver')
    entries = list((DEVICE/'uio').glob('uio*'))
    require(len(entries) == 1, 'Expected one UIO device')
    name = entries[0].name
    base = Path('/sys/class/uio')/name
    require((base/'name').read_text().strip() == 'relay-groundstation', 'UIO name mismatch')
    for key, expected in [('addr', 0x400c1000), ('size', 4096), ('offset', 0)]:
        require(int((base/'maps/map0'/key).read_text(), 0) == expected, 'Wrong map '+key)
    require(len(list((base/'maps').glob('map*'))) == 1, 'Unexpected extra map')
    dev = Path('/dev')/name
    mode = dev.stat()
    require(stat.S_ISCHR(mode.st_mode), 'Not a character device')
    require((base/'dev').read_text().strip() == '%d:%d' % (os.major(mode.st_rdev), os.minor(mode.st_rdev)), 'Device identity mismatch')
    return dev


def start():
    check_parent()
    require(not OVERLAY.exists() and not DEVICE.exists(), 'Already present: inspect status; no duplicate start')
    blob = Path(__file__).with_name('ground_station_uio.dtbo').read_bytes()
    require(hashlib.sha256(blob).hexdigest() == DTBO_SHA, 'Unverified overlay')
    require(DRIVER.is_dir(), 'UIO driver missing')
    OVERLAY.mkdir()
    # Preserve partial failure for inspection; do not silently retry or tear down.
    (OVERLAY/'dtbo').write_bytes(blob)
    require((DEVICE/'of_node/reg').read_bytes().hex() == '400c100000001000', 'Unexpected platform region')
    (DEVICE/'driver_override').write_text('uio_pdrv_genirq')
    (DRIVER/'bind').write_text(DEVICE.name)
    return status()


def stop():
    dev = status()
    with dev.open('rb', buffering=0) as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target = os.fstat(handle.fileno()).st_rdev
        # No cooperating helper may hold its lock; also reject other open FDs.
        for process in Path('/proc').glob('[0-9]*'):
            if process.name == str(os.getpid()):
                continue
            try:
                maps = (process/'maps').read_text()
            except FileNotFoundError:
                continue
            require(str(dev) not in maps, 'Device mapped by PID '+process.name)
            for fd in (process/'fd').glob('*'):
                try:
                    info = fd.stat()
                except FileNotFoundError:
                    continue
                require(not (stat.S_ISCHR(info.st_mode) and info.st_rdev == target), 'Device open by PID '+process.name)
    (DRIVER/'unbind').write_text(DEVICE.name)
    OVERLAY.rmdir()
    require(not DEVICE.exists() and not dev.exists(), 'Removal incomplete')
    return dev


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'status', 'stop'])
    args = parser.parse_args()
    require(os.geteuid() == 0, 'Root required')
    # Serializes this controller; stop still requires all applications quiescent.
    with open('/run/lock/relay-groundstation-uio.lock', 'a') as control_lock:
        fcntl.flock(control_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = {'start': start, 'status': status, 'stop': stop}[args.action]()
        print(json.dumps({'action': args.action, 'device': str(result), 'passed': True}))
