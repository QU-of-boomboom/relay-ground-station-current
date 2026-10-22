"""One owner, one BEGIN, continuous OUTCOME commands with durable intent logs."""
from collections import deque
from dataclasses import asdict
from pathlib import Path
import time
from ledger_station import Journal, MonitorSettings
from monitor_control_client import MonitorControlClient
from online_settlement import OnlineSettlement, OnlineFault
from quality_reference import classify


def command(kind, tag, settings, index=0, delivered=0):
    # Independent production encoding of the unchanged 256-bit command ABI.
    return (kind | (delivered << 8) | (tag << 16) | (settings.epoch << 32) | (settings.node << 96) |
            (settings.session << 128) | (index << 192))


class ContinuousStation:
    def __init__(self, directory, settings, engine, transport_factory, *, journal_factory=None):
        if not isinstance(settings, MonitorSettings) or not isinstance(engine, OnlineSettlement):
            raise ValueError('explicit validated configuration and online engine required')
        if (settings.node, settings.session) != (engine.node, engine.session):
            raise ValueError('engine/configuration identity mismatch')
        if (engine.highest != -1 or engine.stopped or engine.next_index or
                engine.tx_watermark != engine.started-1 or engine.rx_watermark != engine.started-1):
            raise ValueError('fresh unused engine required')
        if not callable(transport_factory):
            raise ValueError('explicit transport factory required')
        self.directory = Path(directory)
        self.settings, self.engine = settings, engine
        self.journal = self.lock = self.client = None
        self.confirmed = self.ordinal = 0
        self.last_receipt = None
        self.last_receipt_ns = None
        self.ring = deque(maxlen=settings.policy.window)
        self.closed = False
        self.failed = False
        lock_path = self.directory/'station.lock'
        try:
            self.lock = lock_path.open('xb')
            if any(p.name != 'station.lock' for p in self.directory.iterdir()):
                raise OnlineFault('new empty generation directory required; no auto-resume')
            self.journal = (journal_factory or Journal)(self.directory/'online.jsonl')
            self.journal.append('header', dict(schema=1, mode=getattr(engine,'mode','deadline_delivery'), settings=asdict(settings),
                started_ns=engine.started, deadline_ns=engine.budget, physical_backend_verified=False,
                **({'deadline_origin':engine.deadline_origin} if engine.deadline_origin!='local_send_observation' else {})))
            self.client = MonitorControlClient(transport_factory(), 0x100, window_size=settings.policy.window)
            self._intent('configure', settings.pack())
            response = self.client.configure(settings.pack())
            if not response.accepted:
                raise OnlineFault('configuration rejected')
            self._result(response)
            self._settle(command(1, 0, settings), 0, 0, 0, 1)
        except BaseException:
            self._abort('START_FAILED')
            self._release()
            raise

    def _intent(self, kind, raw):
        self.journal.append('intent', dict(ordinal=self.ordinal, kind=kind, command=hex(raw)))

    def _result(self, response):
        self.journal.append('result', dict(ordinal=self.ordinal, **asdict(response)))
        self.ordinal += 1

    def _settle(self, raw, count, delivered, index, cache):
        self._intent('settle', raw)
        response = self.client.settle(raw)
        if (not response.accepted or response.bridge_code or response.executor_code or
                (response.count, response.delivered, response.next_index, response.cache_receipt) !=
                (count, delivered, index, cache)):
            raise OnlineFault('PL response mismatch; completion unknown, do not retry')
        self._result(response)
        self.last_receipt=response
        self.last_receipt_ns=time.monotonic_ns()
        return response

    def counter_receipt(self):
        """Last durably confirmed hardware result; reading it does not renew age."""
        if self.failed or self.last_receipt is None:raise OnlineFault('no confirmed counter receipt')
        self.client.check_active()
        return self.last_receipt,self.last_receipt_ns

    def verify_counter_receipt(self):
        """One real query at closure independently checks the cached hardware counts."""
        try:
            expected,_=self.counter_receipt()
            actual=self.client.settle(command(3,0,self.settings))
            if (not actual.accepted or actual.bridge_code or actual.executor_code or actual.cache_receipt or
                    (actual.count,actual.delivered,actual.next_index)!=(expected.count,expected.delivered,expected.next_index)):
                raise OnlineFault('final hardware counter query differs from confirmed receipts')
            self.journal.append('counter_check',dict(**asdict(actual),confirmed_outcomes=self.confirmed))
            return actual
        except BaseException:
            self._abort('COUNTER_CHECK_FAILED')
            raise

    def _abort(self, reason):
        self.failed = True
        self.engine.stop(reason)
        if self.journal is not None:
            try:
                self.journal.append('abort', dict(reason=reason, confirmed_outcomes=self.confirmed))
            except BaseException:
                pass

    def _release(self):
        try:
            if self.journal is not None:
                self.journal.close()
        finally:
            if self.lock is not None:
                self.lock.close()
                (self.directory/'station.lock').unlink()
                self.lock = None

    def tx(self, *args, **kwargs):
        return self._event('tx', *args, **kwargs)

    def rx(self, *args, **kwargs):
        return self._event('rx', *args, **kwargs)

    def _event(self, name, *args, **kwargs):
        if self.closed or self.failed:
            raise OnlineFault('station stopped')
        try:
            value = getattr(self.engine, name)(*args, **kwargs)
            self.journal.append('input', dict(kind=name, args=args, kwargs=kwargs, receipt=value))
            return value
        except BaseException:
            self._abort('INPUT_FAILED')
            raise

    def advance(self, tx_watermark_ns, rx_watermark_ns, now_ns, *, max_outcomes=None):
        if self.closed or self.failed:
            raise OnlineFault('station stopped')
        try:
            record = dict(tx=tx_watermark_ns, rx=rx_watermark_ns, now=now_ns)
            if max_outcomes is not None:
                record['max_outcomes'] = max_outcomes
            self.journal.append('watermarks', record)
            outcomes = self.engine.advance(tx_watermark_ns, rx_watermark_ns, now_ns, max_outcomes=max_outcomes)
            for outcome in outcomes:
                if outcome.index != self.confirmed:
                    raise OnlineFault('outcome order mismatch')
                self.ring.append(int(outcome.delivered))
                self.journal.append('outcome', asdict(outcome))
                self._settle(command(2, (outcome.index+1)&65535, self.settings,
                                     outcome.index, int(outcome.delivered)),
                             len(self.ring), sum(self.ring), outcome.index+1, 1)
                self.confirmed += 1
            return outcomes
        except BaseException:
            self._abort('SETTLEMENT_FAILED')
            raise

    def status(self, now_ns):
        try:
            if not self.closed and not self.failed:
                self.client.check_active()
            status = self.engine.status(now_ns)
        except BaseException:
            self._abort('STATUS_OR_GUARD_FAILED')
            raise
        status.update(confirmed_outcomes=self.confirmed, window_count=len(self.ring),
                      window_delivered=sum(self.ring), board_verified=False)
        status['realtime_eligible'] &= (not self.failed and not self.closed and self.confirmed==self.engine.next_index)
        observed=status['last_closed_ns']
        quality=classify(self.settings.policy,count=len(self.ring),delivered=sum(self.ring),
                         now_ms=now_ns//1_000_000,
                         observation_ms=None if observed is None else observed//1_000_000,
                         update_ok=not self.failed and not self.closed)
        status['pdr_quality']=quality
        status['quality_usable']=bool(status['realtime_eligible'] and quality['usable'])
        return status

    def close(self, reason='NORMAL_STOP'):
        if self.closed:
            return
        self.closed = True
        self.engine.stop(reason)
        try:
            if self.journal is not None:
                self.journal.append('stop', dict(reason=reason, failed=self.failed,
                    confirmed_outcomes=self.confirmed, pending=len(self.engine.pending), realtime_eligible=False))
        finally:
            self._release()
