"""Optional GTS1 DATA payload, authenticated by the enclosing GSR1 message.

The 16-byte clock domain identifies one uninterrupted remote clock lifetime.
Generation is supplied by the sensor adapter, never inferred from file mtime.
"""
from dataclasses import dataclass
import json
from pathlib import Path
import struct

from quality_reference import integer
from remote_round_protocol import MAX_PAYLOAD
from ledger_plan import unique_object

HEADER = struct.Struct('!4sBBH16sQQQ')
MAX_SENSOR_BYTES = MAX_PAYLOAD - HEADER.size
LIMIT = 2**63 - 1


def _sample_fields(domain, generated_ns, payload):
    if type(domain) is not bytes or len(domain) != 16:
        raise ValueError('explicit 128-bit remote clock lifetime required')
    integer(generated_ns, 0, LIMIT)
    if type(payload) is not bytes or len(payload) > MAX_SENSOR_BYTES:
        raise ValueError('bounded sensor payload required')


@dataclass(frozen=True)
class SensorSample:
    clock_domain: bytes
    generated_ns: int
    payload: bytes
    fresh_after_grant: bool = False

    def __post_init__(self):
        _sample_fields(self.clock_domain, self.generated_ns, self.payload)
        if type(self.fresh_after_grant) is not bool:
            raise ValueError('explicit generation provenance required')


@dataclass(frozen=True)
class TimedSample:
    clock_domain: bytes
    generated_ns: int
    grant_received_ns: int
    sent_ns: int
    payload: bytes

    def __post_init__(self):
        _sample_fields(self.clock_domain, self.generated_ns, self.payload)
        integer(self.grant_received_ns, 0, LIMIT)
        integer(self.sent_ns, max(self.generated_ns, self.grant_received_ns), LIMIT)


def encode(sample):
    if not isinstance(sample, TimedSample):
        raise ValueError('validated timed sample required')
    return HEADER.pack(b'GTS1', 1, 0, HEADER.size + len(sample.payload),
                       sample.clock_domain, sample.generated_ns,
                       sample.grant_received_ns, sample.sent_ns) + sample.payload


def decode(payload):
    if type(payload) is not bytes or not HEADER.size <= len(payload) <= MAX_PAYLOAD:
        raise ValueError('timed payload length')
    magic, version, reserved, size, domain, generated, received, sent = HEADER.unpack(payload[:HEADER.size])
    if magic != b'GTS1' or version != 1 or reserved != 0 or size != len(payload):
        raise ValueError('timed payload header')
    return TimedSample(domain, generated, received, sent, payload[HEADER.size:])


def read_sensor_file(path, expected_domain):
    """Read one atomically published sensor snapshot; never use file mtime.

    The producer must timestamp actual acquisition using the responder's
    monotonic clock and boot domain, then atomically replace the complete file.
    """
    with Path(path).open('rb') as stream:
        raw=stream.read(2049)
    if len(raw)>2048:raise ValueError('bounded sensor snapshot required')
    obj=json.loads(raw.decode('utf8'),object_pairs_hook=unique_object)
    if type(obj) is not dict or set(obj)!=set(('schema','clock_domain_hex','generated_ns','payload_hex')):
        raise ValueError('sensor snapshot fields')
    if type(obj['schema']) is not int or obj['schema']!=1:
        raise ValueError('sensor snapshot schema')
    for name in ('clock_domain_hex','payload_hex'):
        if type(obj[name]) is not str:raise ValueError('canonical sensor hex fields')
    domain=bytes.fromhex(obj['clock_domain_hex']);payload=bytes.fromhex(obj['payload_hex'])
    if domain.hex()!=obj['clock_domain_hex'] or payload.hex()!=obj['payload_hex']:
        raise ValueError('canonical sensor hex fields')
    if domain!=expected_domain:raise ValueError('sensor clock lifetime mismatch')
    return SensorSample(domain,obj['generated_ns'],payload,False)
