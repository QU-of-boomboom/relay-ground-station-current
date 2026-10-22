"""Conservative quality dwell and single-relay arbitration; no hardware transport."""
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
import threading

from ledger_station import Journal, MonitorSettings
from quality_reference import integer
from relay_feedback import RelayRuntime, RelayNotReady


class SupervisionFault(RuntimeError):
    pass


@dataclass(frozen=True)
class QualityEvent:
    node: int
    session: int
    epoch: int
    revision: int
    sequence: int
    evaluated_ns: int
    expires_ns: int
    clock_domain: str
    condition: str
    direct_path: bool

    def __post_init__(self):
        integer(self.node, 1, 2**32-1)
        for value in (self.session, self.epoch, self.revision):
            integer(value, 1, 2**64-1)
        integer(self.sequence, 0, 2**64-1)
        integer(self.evaluated_ns, 0, 2**63-2)
        integer(self.expires_ns, self.evaluated_ns+1, 2**63-1)
        if type(self.clock_domain) is not str or not self.clock_domain:
            raise ValueError('explicit clock domain required')
        if self.condition not in ('UNAVAILABLE', 'BAD', 'BAND', 'GOOD'):
            raise ValueError('quality condition')
        if type(self.direct_path) is not bool:
            raise ValueError('explicit path provenance required')


@dataclass(frozen=True)
class DwellPolicy:
    bad_hold_ns: int
    good_hold_ns: int
    max_gap_ns: int

    def __post_init__(self):
        for value in (self.bad_hold_ns, self.good_hold_ns, self.max_gap_ns):
            integer(value, 1, 2**63-1)


class QualityRelaySupervisor:
    def __init__(self, directory, settings, policy, runtime, *, clock_domain, started_ns):
        integer(started_ns, 0, 2**63-1)
        if (not isinstance(settings, (list, tuple)) or not 1 <= len(settings) <= 4
                or not all(isinstance(item, MonitorSettings) for item in settings)):
            raise ValueError('one to four bound node settings required')
        if len({item.node for item in settings}) != len(settings):
            raise ValueError('duplicate node')
        if not isinstance(policy, DwellPolicy) or not isinstance(runtime, RelayRuntime):
            raise ValueError('validated policy and relay runtime required')
        if type(clock_domain) is not str or not clock_domain:
            raise ValueError('explicit clock domain required')
        self.settings = {item.node: item for item in settings}
        self.order = tuple(self.settings)
        self.policy, self.runtime, self.domain = policy, runtime, clock_domain
        self.now = started_ns
        self.started = started_ns
        self.owner = threading.get_ident()
        self.busy = self.closed = False
        self.stopped = None
        self.latest = {}
        self.since = {}
        self.directory = Path(directory)
        self.lock = self.journal = None
        try:
            self.lock = (self.directory/'supervision.lock').open('xb')
            if any(p.name != 'supervision.lock' for p in self.directory.iterdir()):
                raise SupervisionFault('new empty supervision generation required')
            self.journal = Journal(self.directory/'supervision.jsonl')
            self.journal.append('header', dict(schema=1, settings=[asdict(s) for s in settings],
                policy=asdict(policy), clock_domain=clock_domain, started_ns=started_ns))
        except BaseException:
            self._stop('START_FAILED')
            self._release()
            raise

    def _stop(self, reason):
        if self.stopped is None:
            self.stopped = reason
        self.since.clear()
        self.runtime.controller.stop('QUALITY_SUPERVISION_'+reason)

    @contextmanager
    def _operation(self, now_ns):
        if threading.get_ident() != self.owner or self.busy:
            raise SupervisionFault('single owner and nonreentrant operation required')
        if self.closed or self.stopped:
            raise SupervisionFault('supervision stopped')
        self.busy = True
        try:
            integer(now_ns, self.now, 2**63-1)
            self.now = now_ns
            yield
        except BaseException:
            self._stop('OPERATION_FAILED')
            raise
        finally:
            self.busy = False

    def observe(self, event, now_ns):
        with self._operation(now_ns):
            if not isinstance(event, QualityEvent) or event.node not in self.settings:
                raise SupervisionFault('unbound quality event')
            bound = self.settings[event.node]
            if ((event.session, event.epoch, event.revision) !=
                    (bound.session, bound.epoch, bound.revision) or event.clock_domain != self.domain):
                raise SupervisionFault('quality identity or time domain changed')
            integer(event.evaluated_ns, self.started, now_ns)
            previous = self.latest.get(event.node)
            if previous is not None:
                if event.sequence < previous.sequence:
                    return 'OLD'
                if event.sequence == previous.sequence:
                    if event != previous:
                        raise SupervisionFault('quality sequence collision')
                    return 'DUPLICATE'
                if event.evaluated_ns < previous.evaluated_ns:
                    raise SupervisionFault('quality evaluation time regressed')
            self.journal.append('quality', dict(now_ns=now_ns, event=asdict(event)))
            self.latest[event.node] = event
            usable = (event.direct_path and event.condition in ('BAD', 'GOOD')
                      and now_ns < event.expires_ns)
            continuous = (usable and previous is not None and previous.direct_path
                and previous.condition == event.condition
                and event.evaluated_ns < previous.expires_ns
                and event.evaluated_ns-previous.evaluated_ns <= self.policy.max_gap_ns
                and event.node in self.since)
            if not usable:
                self.since.pop(event.node, None)
            elif not continuous:
                self.since[event.node] = event.evaluated_ns
            return 'ACCEPTED'

    def _mature(self, node, condition, now_ns):
        event = self.latest.get(node)
        if event is None or now_ns >= event.expires_ns:
            self.since.pop(node, None)
            return False
        since = self.since.get(node)
        hold = self.policy.bad_hold_ns if condition == 'BAD' else self.policy.good_hold_ns
        return (event.direct_path and event.condition == condition and since is not None
                and event.evaluated_ns-since >= hold)

    def poll(self, now_ns):
        with self._operation(now_ns):
            state = self.runtime.controller.status(now_ns)
            # Expiration revokes all lanes even when feedback itself is unavailable.
            for node in self.order:
                self._mature(node, 'BAD', now_ns)
            if self.runtime.controller.stopped:
                raise SupervisionFault('relay controller stopped: '+self.runtime.controller.stopped)
            if not state['confirmed_valid']:
                return dict(action=None, reason=state['state'], board_verified=False)
            if state['cooldown_remaining_ns']:
                return dict(action=None, reason='COOLDOWN', board_verified=False)
            actual = state['actual']
            target = actual['target_node']
            if actual['enabled'] and target not in self.settings:
                raise SupervisionFault('confirmed relay target is not managed')
            desired = None
            if actual['enabled']:
                if self._mature(target, 'GOOD', now_ns):
                    desired = (False, 0)
            else:
                for node in self.order:
                    if self._mature(node, 'BAD', now_ns):
                        desired = (True, node)
                        break
            if desired is None:
                return dict(action=None, reason='NO_MATURE_CHANGE', board_verified=False)
            self.journal.append('decision', dict(now_ns=now_ns, enabled=desired[0], target_node=desired[1],
                quality_sequence=self.latest[target if actual['enabled'] else desired[1]].sequence,
                applied_command_id=state['applied_command_id']))
            try:
                command = self.runtime.dispatch(*desired, now_ns, permitted=True)
            except RelayNotReady:
                # A concurrent controller mutation is unsupported and must not
                # silently turn a durable decision into an automatic retry.
                raise SupervisionFault('relay changed during single-owner decision')
            self.journal.append('dispatched', dict(command=asdict(command)))
            return dict(action=asdict(command), reason='WAIT_CONFIRM', board_verified=False)

    def _release(self):
        try:
            if self.journal is not None:
                self.journal.close()
        finally:
            if self.lock is not None:
                lock, self.lock = self.lock, None
                lock.close()
                (self.directory/'supervision.lock').unlink()

    def close(self):
        if threading.get_ident() != self.owner or self.busy:
            raise SupervisionFault('owner-only nonreentrant close required')
        if self.closed:
            return
        self.closed = True
        self._stop('CLOSED')
        try:
            if self.journal is not None:
                self.journal.append('stop', dict(reason=self.stopped, physical_off_confirmed=False))
        finally:
            self._release()
