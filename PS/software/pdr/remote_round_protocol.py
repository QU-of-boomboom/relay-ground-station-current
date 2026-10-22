"""Authenticated bounded remote response batches; all timestamps stay at the host.

This measures a host-grant response deadline, not a sender-clock one-way PDR.
Keys are provided by deployment and are never serialized into evidence.
"""
from dataclasses import dataclass
import hmac
import struct
import threading

from quality_reference import integer
from reference import PacketId

GRANT, DATA, FACTS = 1, 2, 3
HEADER = struct.Struct('!4sBBHIQQ16sIHHQ')
MAC_BYTES = 32
MAX_PAYLOAD = 256
MAX_WIRE = HEADER.size + MAX_PAYLOAD + MAC_BYTES
DOMAIN = b'groundstation-remote-round-v1\0'


class RemoteFault(RuntimeError):
    pass


@dataclass(frozen=True)
class Context:
    node: int
    session: int
    round: int
    nonce: bytes
    base: int
    count: int

    def __post_init__(self):
        PacketId(self.node, self.session, self.base)
        integer(self.round, 1, 2**64-1)
        integer(self.count, 1, 64)
        integer(self.base, 0, 2**32-self.count)
        if type(self.nonce) is not bytes or len(self.nonce) != 16:
            raise ValueError('explicit 128-bit run nonce required')


@dataclass(frozen=True)
class Message:
    kind: int
    context: Context
    index: int = 0
    send_mask: int = 0
    payload: bytes = b''
    generated_after_grant: bool = False

    def __post_init__(self):
        if type(self.kind) is not int or self.kind not in (GRANT, DATA, FACTS):
            raise ValueError('message kind')
        if not isinstance(self.context, Context):
            raise ValueError('validated context required')
        integer(self.index, 0, self.context.count-1)
        integer(self.send_mask, 0, (1 << self.context.count)-1)
        if type(self.payload) is not bytes or len(self.payload) > MAX_PAYLOAD:
            raise ValueError('bounded binary payload required')
        if type(self.generated_after_grant) is not bool:
            raise ValueError('explicit generation provenance required')
        if self.kind != DATA and (self.index or self.payload or self.generated_after_grant):
            raise ValueError('non-data reserved fields')
        if self.kind != FACTS and self.send_mask:
            raise ValueError('non-facts reserved mask')


def _key(key):
    if type(key) is not bytes or len(key) != 32:
        raise ValueError('node-specific 32-byte key required')


def encode(message, key):
    _key(key)
    if not isinstance(message, Message):
        raise ValueError('validated message required')
    c = message.context
    # index bit15 records fresh-after-grant provenance; other high bits reserved.
    index = message.index | (int(message.generated_after_grant) << 15)
    body = HEADER.pack(b'GSR1', 1, message.kind,
        HEADER.size + len(message.payload) + MAC_BYTES, c.node, c.session,
        c.round, c.nonce, c.base, c.count, index, message.send_mask) + message.payload
    return body + hmac.digest(key, DOMAIN + body, 'sha256')


def decode(wire, key):
    _key(key)
    if type(wire) is not bytes or not HEADER.size+MAC_BYTES <= len(wire) <= MAX_WIRE:
        raise ValueError('wire length')
    body, tag = wire[:-MAC_BYTES], wire[-MAC_BYTES:]
    if not hmac.compare_digest(hmac.digest(key, DOMAIN + body, 'sha256'), tag):
        raise ValueError('message authentication failed')
    magic, version, kind, size, node, session, turn, nonce, base, count, index, mask = HEADER.unpack(body[:HEADER.size])
    if magic != b'GSR1' or version != 1 or size != len(wire) or index & 0x7fc0:
        raise ValueError('wire header/reserved fields')
    context = Context(node, session, turn, nonce, base, count)
    return Message(kind, context, index & 63, mask, body[HEADER.size:], bool(index & 0x8000))


class DroneResponder:
    """One owner calls this synchronously; repeats return facts, never repeat data.

    sample(sequence) returns (bytes, fresh_after_grant). send(bytes) returns bool.
    A failed sample or ambiguous callback outcome permanently stops this run.
    """
    def __init__(self, *, node, session, nonce, key, first_sequence=0):
        Context(node, session, 1, nonce, first_sequence, 1)
        _key(key)
        self.node, self.session, self.nonce, self.key = node, session, nonce, key
        self.next_sequence = first_sequence
        self.last_context = self.last_facts = None
        self.stopped = False
        self.busy = False
        self.owner = threading.get_ident()

    def grant(self, message, sample, send):
        if threading.get_ident() != self.owner:
            raise RemoteFault('drone responder must use its owner thread')
        if self.stopped or self.busy:
            raise RemoteFault('drone run stopped or reentrant')
        if not isinstance(message, Message) or message.kind != GRANT:
            raise ValueError('grant required')
        c = message.context
        if (c.node, c.session, c.nonce) != (self.node, self.session, self.nonce):
            return 'FOREIGN'
        self.busy = True
        try:
            if self.last_context is not None and c.round <= self.last_context.round:
                if c.round < self.last_context.round:
                    return 'OLD'
                if c != self.last_context:
                    raise RemoteFault('conflicting grant context')
                if type(send(encode(self.last_facts, self.key))) is not bool:
                    raise RemoteFault('send result must be explicit bool')
                return 'FACTS_REPLAY'
            if c.base != self.next_sequence or (self.last_context and c.round != self.last_context.round+1):
                raise RemoteFault('grant sequence/round gap')
            mask = 0
            for index in range(c.count):
                payload, fresh = sample(c.base+index)
                data = Message(DATA, c, index=index, payload=payload, generated_after_grant=fresh)
                result = send(encode(data, self.key))
                if type(result) is not bool:
                    raise RemoteFault('send result must be explicit bool')
                mask |= int(result) << index
            facts = Message(FACTS, c, send_mask=mask)
            # Cache before sending the report; a lost report does not authorize replaying data.
            self.last_context, self.last_facts = c, facts
            self.next_sequence = c.base+c.count
            if type(send(encode(facts, self.key))) is not bool:
                raise RemoteFault('send result must be explicit bool')
            return 'SENT'
        except BaseException:
            self.stopped = True
            raise
        finally:
            self.busy = False


@dataclass(frozen=True)
class ClosedRound:
    context: Context
    started_ns: int
    deadline_ns: int
    closed_ns: int
    send_mask: int
    received: tuple

    @property
    def outcomes(self):
        received = {index: observed for index, observed, _, _ in self.received}
        return tuple((self.context.base+i, received.get(i, self.deadline_ns+1) <= self.deadline_ns)
                     for i in range(self.context.count) if self.send_mask & (1 << i))


class HostRound:
    """Bounded receive state; closure requires a genuine post-deadline empty queue."""
    def __init__(self, context, *, started_ns, budget_ns, facts_timeout_ns):
        if not isinstance(context, Context):
            raise ValueError('validated context required')
        integer(started_ns, 0, 2**63-2)
        integer(budget_ns, 1, 2**63-1-started_ns)
        integer(facts_timeout_ns, budget_ns+1, 2**63-1-started_ns)
        self.context = context
        self.started = self.now = started_ns
        self.deadline = started_ns+budget_ns
        self.timeout = started_ns+facts_timeout_ns
        self.received = {}
        self.mask = None
        self.facts_received = None
        self.closed = self.stopped = None
        self.duplicates = self.foreign = self.late = 0
        self.owner = threading.get_ident()

    def _time(self, now_ns):
        if threading.get_ident() != self.owner:
            raise RemoteFault('host round must use its owner thread')
        if self.stopped:
            raise RemoteFault(self.stopped)
        try:
            integer(now_ns, self.now, 2**63-1)
        except ValueError:
            self._fault('host clock invalid/regressed')
        self.now = now_ns

    def _fault(self, reason):
        self.stopped = reason
        raise RemoteFault(reason)

    def receive(self, message, observed_ns):
        self._time(observed_ns)
        if self.closed is not None:
            raise RemoteFault('round already closed')
        if not isinstance(message, Message) or message.kind not in (DATA, FACTS):
            raise ValueError('data or facts required')
        if message.context != self.context:
            c, expected = message.context, self.context
            if (c.node,c.session,c.nonce,c.round) == (expected.node,expected.session,expected.nonce,expected.round):
                self._fault('conflicting context for active round')
            self.foreign += 1
            return 'FOREIGN'
        if observed_ns >= self.timeout and self.mask is None:
            self._fault('complete TX facts missing at timeout')
        if message.kind == FACTS:
            if self.mask is not None:
                if message.send_mask != self.mask:
                    self._fault('conflicting TX facts')
                self.duplicates += 1
                return 'DUPLICATE'
            if any(not message.send_mask & (1 << i) for i in self.received):
                self._fault('received data contradicts failed send fact')
            self.mask, self.facts_received = message.send_mask, observed_ns
            return 'FACTS'
        index = message.index
        if self.mask is not None and not self.mask & (1 << index):
            self._fault('data contradicts failed send fact')
        old = self.received.get(index)
        if old is not None:
            if old[1:] != (message.payload, message.generated_after_grant):
                self._fault('conflicting data for one sequence')
            self.duplicates += 1
            return 'DUPLICATE'
        self.received[index] = (observed_ns, message.payload, message.generated_after_grant)
        if observed_ns > self.deadline:
            self.late += 1
            return 'LATE'
        return 'DATA'

    def empty_queue(self, sampled_before_empty_ns):
        self._time(sampled_before_empty_ns)
        if self.closed is not None:
            return self.closed
        if self.mask is None:
            if sampled_before_empty_ns >= self.timeout:
                self._fault('complete TX facts missing at timeout')
            return None
        # Future userspace events may have the same coarse timestamp. Commit
        # only strictly older instants; deadline itself is inclusive for RX.
        if sampled_before_empty_ns <= self.deadline:
            return None
        self.closed = ClosedRound(self.context, self.started, self.deadline,
            sampled_before_empty_ns, self.mask,
            tuple((i, *row) for i, row in sorted(self.received.items())))
        return self.closed


def reference_outcomes(context, mask, arrivals, deadline_ns):
    """Batch oracle independent of HostRound and ClosedRound state transitions."""
    return tuple((sequence, any(seq == sequence and time <= deadline_ns for seq, time in arrivals))
                 for sequence in range(context.base, context.base+context.count)
                 if mask & (1 << (sequence-context.base)))
