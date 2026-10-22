"""Normalize saved rpcd iwinfo assoclist data; never infer RF measurement time.

This module performs no network/device access. A caller must bind the response
to its requested AP interface. Router/driver support remains unverified.
"""
from typing import Optional
from dataclasses import asdict, dataclass
import argparse
import hashlib
import json
from pathlib import Path
import re

PROFILE = 'rpcd_iwinfo_assoclist_signed_v1'
MAX_BYTES = 1_048_576
MAX_STATIONS = 1024


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key: ' + key)
        result[key] = value
    return result


def uint(value, maximum, label):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(label + ' must be an unsigned integer in range')
    return value


def mac_address(value):
    if type(value) is not str or not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', value):
        raise ValueError('canonical colon-separated MAC required')
    octets = bytes.fromhex(value.replace(':', ''))
    if octets == bytes(6) or octets[0] & 1:
        raise ValueError('nonzero unicast station MAC required')
    return value.lower()


@dataclass(frozen=True)
class Device:
    node: int
    mac: str


@dataclass(frozen=True)
class Observation:
    node: int
    mac: str
    status: str
    rssi_dbm: Optional[int]
    inactive_raw: Optional[int]
    rx_packets: Optional[int]
    measurement_time_ns: None = None
    measurement_time_verified: bool = False
    realtime_eligible: bool = False


class AssociationMap:
    def __init__(self, interface, devices):
        if type(interface) is not str or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
            raise ValueError('explicit AP interface required')
        if type(devices) is not list or not 1 <= len(devices) <= MAX_STATIONS:
            raise ValueError('bounded nonempty device mapping required')
        rows = []
        for row in devices:
            if type(row) is not dict or set(row) != {'node', 'mac'}:
                raise ValueError('device mapping schema')
            node = uint(row['node'], 2**32-1, 'node')
            rows.append(Device(node, mac_address(row['mac'])))
        if len({r.node for r in rows}) != len(rows) or len({r.mac for r in rows}) != len(rows):
            raise ValueError('device mapping must be one-to-one')
        self.interface = interface
        self.devices = tuple(sorted(rows, key=lambda r: r.node))

    def parse(self, payload, *, response_interface, poll_started_ns, poll_finished_ns):
        """Polling times are local observation metadata, NOT a signal sample time."""
        if response_interface != self.interface:
            raise ValueError('response interface mismatch')
        uint(poll_started_ns, 2**63-1, 'poll start')
        uint(poll_finished_ns, 2**63-1, 'poll finish')
        if poll_finished_ns < poll_started_ns:
            raise ValueError('local poll clock regressed')
        if type(payload) is not bytes or len(payload) > MAX_BYTES:
            raise ValueError('bounded raw JSON bytes required')
        try:
            data = json.loads(payload.decode('utf8'), object_pairs_hook=unique_object,
                              parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
        except (UnicodeError, RecursionError) as error:
            raise ValueError('invalid JSON encoding/depth') from error
        if type(data) is not dict or set(data) != {'results'} or type(data['results']) is not list:
            raise ValueError('full assoclist results schema required')
        if len(data['results']) > MAX_STATIONS:
            raise ValueError('too many stations')
        found = {}
        for row in data['results']:
            if type(row) is not dict or 'mac' not in row:
                raise ValueError('association row schema')
            mac = mac_address(row['mac'])
            if mac in found:
                raise ValueError('duplicate station association')
            signal = row.get('signal')
            if signal is not None and (type(signal) is not int or not -128 <= signal <= 0):
                raise ValueError('signed int8 RSSI profile required; unsigned/string/positive unsupported')
            inactive = row.get('inactive')
            if inactive is not None:
                uint(inactive, 2**32-1, 'inactive')
            rx = row.get('rx', {})
            if type(rx) is not dict:
                raise ValueError('rx counters schema')
            count = rx.get('packets')
            if count is not None:
                uint(count, 2**32-1, 'rx packets')
            # Zero and the extreme sentinel are conservative unavailable values.
            rssi = signal if signal is not None and -127 <= signal <= -1 else None
            found[mac] = (rssi, inactive, count)
        observations = []
        for device in self.devices:
            if device.mac not in found:
                result = Observation(device.node, device.mac, 'NOT_LISTED', None, None, None)
            else:
                signal, inactive, count = found[device.mac]
                status = 'PRESENT_UNTIMED' if signal is not None else 'SIGNAL_UNAVAILABLE'
                result = Observation(device.node, device.mac, status, signal, inactive, count)
            observations.append(asdict(result))
        return dict(schema=1, profile=PROFILE, interface=self.interface,
                    poll_started_ns=poll_started_ns, poll_finished_ns=poll_finished_ns,
                    input_sha256=hashlib.sha256(payload).hexdigest(), observations=observations,
                    unmapped_stations=len(set(found)-{d.mac for d in self.devices}),
                    measurement_time_verified=False, realtime_eligible=False, router_verified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--mapping', type=Path, required=True)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--poll-start-ns', type=int, required=True)
    parser.add_argument('--poll-finish-ns', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with args.mapping.open('rb') as stream:
        raw = stream.read(MAX_BYTES+1)
    if len(raw) > MAX_BYTES:
        raise ValueError('mapping too large')
    config = json.loads(raw, object_pairs_hook=unique_object)
    if type(config) is not dict or set(config) != {'interface', 'devices'}:
        raise ValueError('mapping file schema')
    mapping = AssociationMap(**config)
    with args.input.open('rb') as stream:
        payload = stream.read(MAX_BYTES+1)
    result = mapping.parse(payload, response_interface=args.interface,
                           poll_started_ns=args.poll_start_ns, poll_finished_ns=args.poll_finish_ns)
    with args.output.open('x', encoding='utf8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
