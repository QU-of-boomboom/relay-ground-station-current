"""Conditional causal bounds for authenticated remote generation timestamps.

The caller authenticates and correlates the four timestamps before calling us.
RateEvidence is an explicit deployment premise, not a clock calibration tool.
No network symmetry, offset estimate, floating point or RTT/2 is used here.
"""
from collections import deque
from dataclasses import dataclass
import threading

from quality_reference import integer
from reference import PacketId
from timing_metrics import GenerationBounds

LIMIT = 2**63 - 1
SCALE = 1_000_000


class MappingFault(RuntimeError):
    pass


def _domain(value):
    if type(value) is not str or not value or len(value) > 128:
        raise ValueError('explicit bounded clock domain required')


@dataclass(frozen=True)
class RateEvidence:
    ppm: int
    reference: str | None = None

    def __post_init__(self):
        integer(self.ppm, 0, SCALE - 1)
        if self.reference is not None and (
                type(self.reference) is not str or not self.reference.strip()
                or len(self.reference) > 512):
            raise ValueError('explicit rate evidence reference required')


@dataclass(frozen=True)
class Exchange:
    node: int
    session: int
    remote_domain: str
    sequence: int
    host_send_ns: int
    remote_receive_ns: int
    remote_send_ns: int
    host_receive_ns: int

    def __post_init__(self):
        PacketId(self.node, self.session, 0)
        _domain(self.remote_domain)
        integer(self.sequence, 0, 2**64 - 1)
        integer(self.host_send_ns, 0, LIMIT)
        integer(self.host_receive_ns, self.host_send_ns, LIMIT)
        integer(self.remote_receive_ns, 0, LIMIT)
        integer(self.remote_send_ns, self.remote_receive_ns, LIMIT)


@dataclass(frozen=True)
class MappingResult:
    reason: str
    lower_ns: int | None = None
    upper_ns: int | None = None
    generation: GenerationBounds | None = None
    anchors: int = 0


def _floor_delta(delta, ppm):
    numerator = delta * (SCALE - ppm if delta >= 0 else SCALE + ppm)
    return numerator // SCALE


def _ceil_delta(delta, ppm):
    numerator = delta * (SCALE + ppm if delta >= 0 else SCALE - ppm)
    return -((-numerator) // SCALE)


def causal_interval(exchange, remote_generation_ns, ppm):
    """Outward-rounded interval; negative bounds remain negative diagnostics."""
    if not isinstance(exchange, Exchange):
        raise ValueError('validated exchange required')
    integer(remote_generation_ns, 0, LIMIT)
    integer(ppm, 0, SCALE - 1)
    return (
        exchange.host_send_ns + _floor_delta(
            remote_generation_ns - exchange.remote_receive_ns, ppm),
        exchange.host_receive_ns + _ceil_delta(
            remote_generation_ns - exchange.remote_send_ns, ppm),
    )


class ClockMapping:
    """Bounded, sequential exchange history with immutable observation times.

    Sequence identifiers refer to completed, non-overlapping clock probes.
    Foreign node/session exchanges are ignored; a clock-domain change in the
    bound run or contradictory time evidence permanently stops this mapper.
    This class must have the same single owner as its authenticated adapter.
    """
    def __init__(self, *, node, session, remote_domain, host_domain, rate,
                 started_ns, max_anchor_age_ns, max_extrapolation_ns,
                 capacity=8):
        PacketId(node, session, 0)
        _domain(remote_domain)
        _domain(host_domain)
        if not isinstance(rate, RateEvidence):
            raise ValueError('explicit rate premise required')
        integer(started_ns, 0, LIMIT)
        integer(max_anchor_age_ns, 1, LIMIT)
        integer(max_extrapolation_ns, 1, LIMIT)
        integer(capacity, 1, 64)
        self.node, self.session = node, session
        self.remote_domain, self.host_domain = remote_domain, host_domain
        self.rate = rate
        self.now = started_ns
        self.started = started_ns
        self.owner = threading.get_ident()
        self.max_age = max_anchor_age_ns
        self.max_extrapolation = max_extrapolation_ns
        self.anchors = deque(maxlen=capacity)
        self.last = None
        self.stopped = None

    def _fault(self, reason):
        self.stopped = self.stopped or reason
        raise MappingFault(self.stopped)

    def _time(self, now_ns):
        if threading.get_ident() != self.owner:
            self._fault('clock mapper must use its owner thread')
        if self.stopped:
            raise MappingFault(self.stopped)
        try:
            integer(now_ns, self.now, LIMIT)
        except ValueError:
            self._fault('host processing clock invalid/regressed')
        self.now = now_ns
        while self.anchors and now_ns - self.anchors[0].host_receive_ns >= self.max_age:
            self.anchors.popleft()

    def observe(self, exchange, now_ns):
        self._time(now_ns)
        if not isinstance(exchange, Exchange):
            self._fault('validated authenticated exchange required')
        if (exchange.node, exchange.session) != (self.node, self.session):
            return 'FOREIGN'
        if exchange.remote_domain != self.remote_domain:
            self._fault('remote clock domain changed')
        if exchange.host_receive_ns > now_ns or exchange.host_send_ns < self.started:
            self._fault('host observation outside this run')
        previous = self.last
        if previous is not None:
            if exchange.sequence < previous.sequence:
                return 'OLD'
            if exchange.sequence == previous.sequence:
                if exchange != previous:
                    self._fault('conflicting exchange with same sequence')
                return 'DUPLICATE'
            if (exchange.host_send_ns < previous.host_receive_ns
                    or exchange.remote_receive_ns < previous.remote_send_ns):
                self._fault('overlapping exchange or clock regression')
        # Even an expired exchange advances the anti-replay high watermark.
        self.last = exchange
        if now_ns - exchange.host_receive_ns >= self.max_age:
            return 'STALE'
        # Check consistency at this exchange's remote receive instant. The
        # remote processing interval itself may exceed the allowed host RTT.
        lower, upper = causal_interval(exchange, exchange.remote_receive_ns, self.rate.ppm)
        for anchor in self.anchors:
            if abs(exchange.remote_receive_ns - anchor.remote_receive_ns) <= self.max_extrapolation and abs(exchange.remote_receive_ns - anchor.remote_send_ns) <= self.max_extrapolation:
                lo, hi = causal_interval(anchor, exchange.remote_receive_ns, self.rate.ppm)
                lower, upper = max(lower, lo), min(upper, hi)
        if lower > upper:
            self._fault('inconsistent exchange/rate evidence')
        self.anchors.append(exchange)
        return 'ACCEPTED'

    def generation(self, *, node, session, remote_domain, generated_ns,
                   remote_sent_ns, received_ns, now_ns):
        self._time(now_ns)
        try:
            PacketId(node, session, 0)
            _domain(remote_domain)
            integer(generated_ns, 0, LIMIT)
            integer(remote_sent_ns, generated_ns, LIMIT)
            integer(received_ns, 0, now_ns)
        except ValueError:
            self._fault('invalid generation/send/receive evidence')
        if (node, session) != (self.node, self.session):
            return MappingResult('FOREIGN')
        if remote_domain != self.remote_domain:
            self._fault('remote clock domain changed')
        intervals = [causal_interval(anchor, generated_ns, self.rate.ppm)
                     for anchor in self.anchors
                     if abs(generated_ns - anchor.remote_receive_ns) <= self.max_extrapolation
                     and abs(generated_ns - anchor.remote_send_ns) <= self.max_extrapolation]
        if not intervals:
            return MappingResult('NO_FRESH_ANCHOR' if not self.anchors else 'EXTRAPOLATION_LIMIT')
        lower = max(lo for lo, _ in intervals)
        # Generation precedes this authenticated packet's remote send, which
        # causally precedes local receipt. This is an additional valid bound.
        upper = min(received_ns, min(hi for _, hi in intervals))
        if lower > upper:
            self._fault('generation contradicts causal/rate evidence')
        if lower < 0 or upper > LIMIT:
            return MappingResult('HOST_RANGE_UNKNOWN', lower, upper, anchors=len(intervals))
        if self.rate.reference is None:
            return MappingResult('RATE_UNVERIFIED', lower, upper, anchors=len(intervals))
        return MappingResult('BOUNDED', lower, upper,
                             GenerationBounds(lower, upper, self.host_domain), len(intervals))
