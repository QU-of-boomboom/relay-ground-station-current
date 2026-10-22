"""Bounded continuous deadline-delivery settlement in one local clock domain."""
from collections import deque
from dataclasses import asdict, dataclass
from quality_reference import integer
from reference import PacketId


class OnlineFault(RuntimeError):
    pass


@dataclass(frozen=True)
class Outcome:
    index: int
    sequence: int
    observed_ns: int
    deadline_ns: int
    delivered: bool


class OnlineSettlement:
    def __init__(self, *, node, session, started_ns, deadline_ns, capacity=256,
                 source_timeout_ns=1_000_000_000, statistics_age_ns=1_000_000_000,
                 deadline_origin='local_send_observation'):
        PacketId(node, session, 0)
        integer(started_ns, 0, 2**63-1)
        integer(deadline_ns, 1, 2**63-1)
        integer(capacity, 1, 4096)
        integer(source_timeout_ns, 1, 2**63-1)
        integer(statistics_age_ns, 1, 2**63-1)
        if deadline_origin not in ('local_send_observation','host_grant'):
            raise ValueError('explicit supported deadline origin required')
        self.deadline_origin=deadline_origin
        self.node, self.session = node, session
        self.started = self.now = started_ns
        self.budget, self.capacity = deadline_ns, capacity
        self.timeout, self.max_age = source_timeout_ns, statistics_age_ns
        self.tx_watermark = self.rx_watermark = started_ns-1
        self.last_tx_time = self.last_rx_time = started_ns-1
        self.pending = deque()
        self.by_sequence = {}
        self.highest = -1
        self.next_index = self.sent = self.failed = self.delivered = 0
        self.duplicates = self.late = self.unmatched = self.foreign = 0
        self.last_closed = None
        self.stopped = None

    def stop(self, reason):
        if type(reason) is not str or not reason:
            raise ValueError('explicit stop reason required')
        if self.stopped is None:
            self.stopped = reason

    def fault(self, reason):
        self.stop(reason)
        raise OnlineFault(reason)

    def _time(self, now):
        if self.stopped:
            raise OnlineFault('stopped: '+self.stopped)
        try:
            integer(now, self.now, 2**63-1)
        except ValueError:
            self.fault('local clock invalid/regressed')
        self.now = now

    def _event(self, observed, watermark, previous):
        try:
            integer(observed, self.started, self.now)
        except ValueError:
            self.fault('event time outside current local run')
        if observed <= watermark or observed < previous:
            self.fault('event behind input watermark/order')

    def tx(self, sequence, send_ok, observed_ns, now_ns):
        self._time(now_ns)
        self._event(observed_ns, self.tx_watermark, self.last_tx_time)
        try:
            PacketId(self.node, self.session, sequence)
        except ValueError:
            self.fault('invalid sequence')
        if type(send_ok) is not bool or sequence <= self.highest:
            self.fault('TX sequence/order or send result invalid')
        if send_ok and (len(self.pending) >= self.capacity or observed_ns > 2**63-1-self.budget):
            self.fault('inflight capacity/time exhausted')
        self.highest, self.last_tx_time = sequence, observed_ns
        if not send_ok:
            self.failed += 1
            return
        item = dict(sequence=sequence, observed=observed_ns, deadline=observed_ns+self.budget, received=False)
        self.pending.append(item)
        self.by_sequence[sequence] = item
        self.sent += 1

    def rx(self, node, session, sequence, observed_ns, now_ns):
        self._time(now_ns)
        self._event(observed_ns, self.rx_watermark, self.last_rx_time)
        try:
            PacketId(node, session, sequence)
        except ValueError:
            self.fault('invalid received identity')
        self.last_rx_time = observed_ns
        if (node, session) != (self.node, self.session):
            self.foreign += 1
            return 'FOREIGN'
        item = self.by_sequence.get(sequence)
        if item is None:
            self.unmatched += 1
            return 'UNMATCHED_OR_CLOSED'
        if observed_ns < item['observed']:
            self.fault('RX precedes registered TX observation')
        if observed_ns > item['deadline']:
            self.late += 1
            return 'LATE'
        if item['received']:
            self.duplicates += 1
            return 'DUPLICATE'
        item['received'] = True
        return 'DELIVERED'

    def advance(self, tx_watermark_ns, rx_watermark_ns, now_ns, *, max_outcomes=None):
        if max_outcomes is not None:
            integer(max_outcomes, 1, 4096)
        self._time(now_ns)
        try:
            integer(tx_watermark_ns, self.tx_watermark, now_ns)
            integer(rx_watermark_ns, self.rx_watermark, now_ns)
        except ValueError:
            self.fault('invalid input watermark')
        self.tx_watermark, self.rx_watermark = tx_watermark_ns, rx_watermark_ns
        closed = []
        minimum = min(tx_watermark_ns, rx_watermark_ns)
        while self.pending and self.pending[0]['deadline'] <= minimum:
            if max_outcomes is not None and len(closed) >= max_outcomes:
                break
            if self.next_index >= 0xffffffff:
                self.fault('PL outcome index exhausted')
            item = self.pending.popleft()
            del self.by_sequence[item['sequence']]
            outcome = Outcome(self.next_index, item['sequence'], item['observed'], item['deadline'], item['received'])
            self.next_index += 1
            self.delivered += int(outcome.delivered)
            self.last_closed = outcome.deadline_ns
            closed.append(outcome)
        return tuple(closed)

    def status(self, now_ns):
        if not self.stopped:
            self._time(now_ns)
        else:
            integer(now_ns, self.now, 2**63-1)
        fresh_sources = (now_ns-min(self.tx_watermark, self.rx_watermark) < self.timeout)
        fresh_stats = self.last_closed is not None and now_ns-self.last_closed < self.max_age
        backlog = bool(self.pending and self.pending[0]['deadline'] <= min(self.tx_watermark, self.rx_watermark))
        result=dict(mode='deadline_delivery', active=self.stopped is None, stop_reason=self.stopped,
                    realtime_eligible=self.stopped is None and fresh_sources and fresh_stats and not backlog,
                    settlement_backlog=backlog,
                    sent=self.sent, local_send_failures=self.failed, settled=self.next_index,
                    delivered=self.delivered, missed_deadline=self.next_index-self.delivered,
                    pending=len(self.pending), duplicates=self.duplicates, late=self.late,
                    unmatched=self.unmatched, foreign=self.foreign, last_closed_ns=self.last_closed)
        if self.deadline_origin!='local_send_observation':result['deadline_origin']=self.deadline_origin
        return result


def reference_outcomes(sends, receives, watermark_ns, budget_ns):
    """Independent batch oracle, used only in tests: no engine state or calls."""
    result = []
    for sequence, ok, observed in sends:
        if ok and observed+budget_ns <= watermark_ns:
            result.append((sequence, any(s == sequence and observed <= t <= observed+budget_ns
                                         for s,t in receives)))
    return result
