"""Durable, single-owner execution of closed ledgers; NEVER grants live health."""
from collections import deque
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re

from ledger_plan import plan, unique_object
from monitor_control_client import MonitorControlClient
from quality_reference import Policy, integer
from reference import PacketId


class LedgerExecutionError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


@dataclass(frozen=True)
class MonitorSettings:
    node: int
    session: int
    epoch: int
    revision: int
    policy: Policy

    def __post_init__(self):
        PacketId(self.node, self.session, 0)
        integer(self.epoch, 1, 2**64-1)
        integer(self.revision, 1, 2**64-1)
        if not isinstance(self.policy, Policy):
            raise ValueError('Policy required')

    def pack(self):
        p = self.policy
        values = (self.node, self.session, self.epoch, self.revision,
                  p.window, p.min_count, p.low_permille, p.high_permille, p.max_age_ms)
        value = 0
        for field, width in zip(values, (32,64,64,64,9,9,10,10,64)):
            value = (value << width) | field
        return value


@dataclass(frozen=True)
class PreparedLedger:
    settings: MonitorSettings
    digest: str
    commands: tuple
    outcomes: tuple
    successful_sends: int
    local_send_failures: int
    delivered: int
    lost: int


@dataclass(frozen=True)
class LedgerResult:
    successful_sends: int
    local_send_failures: int
    delivered: int
    lost: int
    window_count: int
    window_delivered: int
    next_index: int
    commands_confirmed: int
    realtime_eligible: bool = False


def prepare(batch, settings):
    if not isinstance(settings, MonitorSettings):
        raise ValueError('MonitorSettings required')
    if type(batch) is not dict or type(batch.get('sent')) is not list or type(batch.get('received')) is not list:
        raise ValueError('ledger object and arrays required')
    if len(batch['sent']) > 4096 or len(batch['received']) > 16384:
        raise ValueError('bounded batch capacity exceeded')
    # Freeze caller-owned containers before planning or opening any backend.
    frozen = json.loads(canonical(batch), object_pairs_hook=unique_object)
    planned = plan(frozen)
    if (planned['node'], planned['session'], planned['epoch']) != (settings.node, settings.session, settings.epoch):
        raise ValueError('ledger/configuration identity mismatch')
    commands = tuple(sum(w << (32*i) for i,w in enumerate(words)) for words in planned['commands'])
    digest = hashlib.sha256(canonical(dict(batch=frozen, settings=asdict(settings))).encode('utf8')).hexdigest()
    return PreparedLedger(settings, digest, commands, tuple(int(row['received']) for row in planned['outcomes']),
                          planned['successful_sends'], planned['local_send_failures'], planned['delivered'], planned['lost'])


def audit_journal(path):
    """Validate both hash chain and intent/result order; incomplete is not success."""
    previous = '0'*64
    pending = None
    confirmed = 0
    status = 'incomplete'
    header = None
    lines = Path(path).read_bytes().splitlines(keepends=True)
    if not lines:
        raise LedgerExecutionError('empty execution journal')
    for index,line in enumerate(lines):
        if not line.endswith(b'\n') or status != 'incomplete':
            raise LedgerExecutionError('truncated or trailing execution record')
        row = json.loads(line, object_pairs_hook=unique_object)
        if type(row) is not dict or set(row) != {'sequence','previous','kind','data','sha256'}:
            raise LedgerExecutionError('journal schema')
        digest = row.pop('sha256')
        if row['sequence'] != index or type(row['sequence']) is not int or row['previous'] != previous:
            raise LedgerExecutionError('journal chain order')
        if hashlib.sha256(canonical(row).encode('utf8')).hexdigest() != digest:
            raise LedgerExecutionError('journal hash')
        previous = digest
        kind,data = row['kind'],row['data']
        if index == 0:
            if kind != 'header' or data.get('schema') != 1 or data.get('realtime_eligible') is not False:
                raise LedgerExecutionError('journal header')
            header = data
        elif kind == 'intent':
            if pending is not None or data.get('ordinal') != confirmed:
                raise LedgerExecutionError('intent order')
            pending = confirmed
        elif kind == 'result':
            if pending is None or data.get('ordinal') != pending or data.get('accepted') is not True:
                raise LedgerExecutionError('result order or rejection')
            pending = None
            confirmed += 1
        elif kind == 'complete':
            if pending is not None or data.get('commands_confirmed') != confirmed or data.get('realtime_eligible') is not False:
                raise LedgerExecutionError('completion mismatch')
            if confirmed != header['commands_expected']:
                raise LedgerExecutionError('missing commands')
            status = 'complete'
        elif kind == 'abort':
            if data.get('confirmed') != confirmed:
                raise LedgerExecutionError('abort count')
            status = 'aborted'
        else:
            raise LedgerExecutionError('unexpected execution record')
    return dict(status=status, confirmed=confirmed, pending=pending, header=header, last_hash=previous)


class Journal:
    def __init__(self, path):
        self.file = Path(path).open('xb')
        self.sequence = 0
        self.previous = '0'*64

    def append(self, kind, data):
        row = dict(sequence=self.sequence, previous=self.previous, kind=kind, data=data)
        digest = hashlib.sha256(canonical(row).encode('utf8')).hexdigest()
        row['sha256'] = digest
        self.file.write((canonical(row)+'\n').encode('utf8'))
        self.file.flush()
        os.fsync(self.file.fileno())
        self.previous = digest
        self.sequence += 1

    def close(self):
        self.file.close()


class ClosedLedgerRunner:
    """A run directory is a station generation; failed generations never auto-resume."""
    def __init__(self, directory, transport_factory, *, control_base=0x100, poll_limit=1000):
        integer(control_base,0,0xffffffff-0x9c)
        if control_base%4:raise ValueError('aligned control base required')
        integer(poll_limit,1,2**31-1)
        if not callable(transport_factory):raise ValueError('transport factory required')
        self.directory = Path(directory)
        self.transport_factory = transport_factory
        self.control_base = control_base
        self.poll_limit = poll_limit
        self.used = False

    def run(self, batch, settings):
        prepared = prepare(batch, settings)
        if self.used:
            raise LedgerExecutionError('runner already used; no retry')
        if not self.directory.is_dir():
            raise ValueError('existing dedicated run directory required')
        self.used = True
        lock_path = self.directory/'station.lock'
        # O_EXCL is the cross-process exclusion boundary, not a preliminary exists check.
        lock = lock_path.open('xb')
        journal = None
        confirmed = 0
        try:
            lock.write(b'closed-ledger owner; preserve on crash\n')
            lock.flush()
            os.fsync(lock.fileno())
            maximum = 0
            maximum_revision = 0
            for path in self.directory.iterdir():
                if path.name == 'station.lock':
                    continue
                match = re.fullmatch(r'n([0-9a-f]{8})_s([0-9a-f]{16})_e([0-9a-f]{16})\.jsonl', path.name)
                if not match or not path.is_file():
                    raise LedgerExecutionError('unexpected registry entry')
                audit = audit_journal(path)
                if audit['status'] != 'complete':
                    raise LedgerExecutionError('previous incomplete/failed generation; explicit recovery required')
                node,session,epoch = (int(v,16) for v in match.groups())
                h = audit['header']
                if (h['node'],h['session'],h['epoch']) != (node,session,epoch):
                    raise LedgerExecutionError('registry filename/header mismatch')
                # One hardware executor/configuration bank owns the station,
                # so changing node/session does not reset their monotonic IDs.
                maximum = max(maximum,epoch)
                maximum_revision = max(maximum_revision,h['revision'])
            if settings.epoch <= maximum:
                raise LedgerExecutionError('epoch already used or regressed')
            if settings.revision <= maximum_revision:
                raise LedgerExecutionError('configuration revision already used or regressed')
            filename = f'n{settings.node:08x}_s{settings.session:016x}_e{settings.epoch:016x}.jsonl'
            journal = Journal(self.directory/filename)
            journal.append('header',dict(schema=1,node=settings.node,session=settings.session,epoch=settings.epoch,
                revision=settings.revision,window=settings.policy.window,digest=prepared.digest,
                commands_expected=len(prepared.commands)+1,realtime_eligible=False))
            client = MonitorControlClient(self.transport_factory(),self.control_base,
                                          poll_limit=self.poll_limit,window_size=settings.policy.window)
            journal.append('intent',dict(ordinal=confirmed,kind='configure',command=hex(settings.pack())))
            configured = client.configure(settings.pack())
            if not configured.accepted:
                raise LedgerExecutionError('configuration rejected')
            journal.append('result',dict(ordinal=confirmed,**asdict(configured)))
            confirmed += 1
            ring = deque(maxlen=settings.policy.window)
            index = 0
            for ordinal,command in enumerate(prepared.commands):
                if 0 < ordinal <= len(prepared.outcomes):
                    ring.append(prepared.outcomes[ordinal-1])
                    index += 1
                journal.append('intent',dict(ordinal=confirmed,kind='settle',command=hex(command)))
                response = client.settle(command)
                expected_cache = 0 if ordinal == len(prepared.commands)-1 else 1
                if (not response.accepted or response.bridge_code or response.executor_code or
                        response.cache_receipt != expected_cache or
                        (response.count,response.delivered,response.next_index) != (len(ring),sum(ring),index)):
                    raise LedgerExecutionError('settlement receipt/count/index mismatch; no retry')
                journal.append('result',dict(ordinal=confirmed,**asdict(response)))
                confirmed += 1
            result = LedgerResult(prepared.successful_sends,prepared.local_send_failures,prepared.delivered,prepared.lost,
                                  len(ring),sum(ring),index,confirmed)
            journal.append('complete',asdict(result))
            return result
        except BaseException as error:
            if journal is not None:
                try:
                    journal.append('abort',dict(confirmed=confirmed,error=type(error).__name__))
                except BaseException:
                    pass  # The durable intent/incomplete chain remains a recovery blocker.
            raise
        finally:
            if journal is not None:
                journal.close()
            lock.close()
            lock_path.unlink()
