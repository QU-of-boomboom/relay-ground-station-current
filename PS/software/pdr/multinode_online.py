"""Single-owner, bounded round-robin execution of independent online nodes."""
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
import threading

from ledger_station import MonitorSettings
from online_settlement import OnlineFault, OnlineSettlement
from online_station import ContinuousStation
from quality_reference import integer


@dataclass(frozen=True)
class SlotSettings:
    slot: int
    monitor: MonitorSettings
    deadline_ns: int
    capacity: int = 256
    source_timeout_ns: int = 1_000_000_000
    statistics_age_ns: int = 1_000_000_000
    deadline_origin: str = 'local_send_observation'

    def engine(self, started_ns):
        integer(self.slot, 0, 3)
        if not isinstance(self.monitor, MonitorSettings):
            raise ValueError('validated monitor settings required')
        return OnlineSettlement(node=self.monitor.node, session=self.monitor.session,
            started_ns=started_ns, deadline_ns=self.deadline_ns, capacity=self.capacity,
            source_timeout_ns=self.source_timeout_ns, statistics_age_ns=self.statistics_age_ns,
            deadline_origin=self.deadline_origin)


class MultiNodeOnline:
    def __init__(self, directory, slots, transport_factory, *, started_ns, quantum=4):
        integer(quantum, 1, 64)
        if not isinstance(slots, (tuple, list)) or not 1 <= len(slots) <= 4:
            raise ValueError('one to four explicit slots required')
        if not all(isinstance(spec, SlotSettings) for spec in slots):
            raise ValueError('SlotSettings required')
        specs = tuple(slots)
        # Validate every lane before opening a backend or creating any run files.
        engines = tuple(spec.engine(started_ns) for spec in specs)
        if len({spec.slot for spec in specs}) != len(specs):
            raise ValueError('duplicate hardware slot')
        if len({spec.monitor.node for spec in specs}) != len(specs):
            raise ValueError('each node must own exactly one slot')
        if not callable(transport_factory):
            raise ValueError('explicit slot transport factory required')
        self.owner = threading.get_ident()
        self.busy = self.closed = self.failed = False
        self.stations = {}
        self.order = tuple(spec.slot for spec in specs)
        self.cursor = self.rounds = 0
        self.quantum = quantum
        self.directory = Path(directory)
        self.lock = None
        self.cleanup_errors = []
        self.last_now = started_ns
        try:
            self.lock = (self.directory / 'multinode.lock').open('xb')
            if any(p.name != 'multinode.lock' for p in self.directory.iterdir()):
                raise OnlineFault('new empty multinode generation required; no auto-resume')
            for spec, engine in zip(specs, engines):
                lane = self.directory / f'slot{spec.slot}'
                lane.mkdir()
                self.stations[spec.slot] = ContinuousStation(lane, spec.monitor, engine,
                    lambda slot=spec.slot: transport_factory(slot))
        except BaseException:
            # Include engines whose station constructor did not complete.
            for engine in engines:
                engine.stop('MULTINODE_START_FAILED')
            self._stop_all('MULTINODE_START_FAILED', failed=True)
            raise

    def _owner_check(self):
        if threading.get_ident() != self.owner:
            raise OnlineFault('multinode manager must be used by its owner thread')
        if self.busy:
            raise OnlineFault('reentrant multinode transaction forbidden')

    @contextmanager
    def _operation(self):
        self._owner_check()
        if self.closed or self.failed:
            raise OnlineFault('multinode generation stopped')
        self.busy = True
        try:
            yield
        except BaseException:
            self._stop_all('MULTINODE_OPERATION_FAILED', failed=True)
            raise
        finally:
            self.busy = False

    def _station(self, slot):
        if type(slot) is not int or slot not in self.stations:
            raise ValueError('slot is not configured')
        return self.stations[slot]

    def tx(self, slot, sequence, send_ok, observed_ns, now_ns):
        with self._operation():
            return self._station(slot).tx(sequence, send_ok, observed_ns, now_ns)

    def rx(self, slot, node, session, sequence, observed_ns, now_ns):
        with self._operation():
            return self._station(slot).rx(node, session, sequence, observed_ns, now_ns)

    def poll(self, watermarks, now_ns):
        with self._operation():
            integer(now_ns, self.last_now, 2**63-1)
            if (type(watermarks) is not dict or any(type(k) is not int for k in watermarks)
                    or set(watermarks) != set(self.order)):
                raise ValueError('explicit watermarks for every configured slot required')
            # Reject bad later-lane inputs before issuing any earlier-lane command.
            for slot, pair in watermarks.items():
                if not isinstance(pair, (tuple, list)) or len(pair) != 2:
                    raise ValueError('TX and RX watermark pair required')
                engine = self.stations[slot].engine
                integer(now_ns, engine.now, 2**63-1)
                integer(pair[0], engine.tx_watermark, now_ns)
                integer(pair[1], engine.rx_watermark, now_ns)
            order = self.order[self.cursor:] + self.order[:self.cursor]
            counts = {}
            for slot in order:
                outcomes = self.stations[slot].advance(*watermarks[slot], now_ns,
                                                       max_outcomes=self.quantum)
                counts[slot] = len(outcomes)
            self.last_now = now_ns
            status = {slot: self.stations[slot].status(now_ns) for slot in self.order}
            self.cursor = (self.cursor + 1) % len(self.order)
            self.rounds += 1
            return dict(round=self.rounds, order=order, committed=counts, nodes=status,
                        board_verified=False)

    def status(self, now_ns):
        with self._operation():
            integer(now_ns, self.last_now, 2**63-1)
            result = {slot: self.stations[slot].status(now_ns) for slot in self.order}
            self.last_now = now_ns
            return result

    def _stop_all(self, reason, *, failed):
        self.closed = True
        self.failed |= failed
        # Revoke ALL lanes before the first potentially failing journal operation.
        for station in self.stations.values():
            station.engine.stop(reason)
        for station in self.stations.values():
            try:
                if failed and not station.failed:
                    station._abort(reason)
                station.close(reason)
            except BaseException as error:
                self.cleanup_errors.append(repr(error))
        if self.lock is not None:
            lock, self.lock = self.lock, None
            try:
                lock.close()
                (self.directory / 'multinode.lock').unlink()
            except BaseException as error:
                self.cleanup_errors.append(repr(error))

    def close(self, reason='NORMAL_STOP'):
        self._owner_check()
        if type(reason) is not str or not reason:
            raise ValueError('explicit close reason required')
        if not self.closed:
            self._stop_all(reason, failed=False)
        if self.cleanup_errors:
            raise OnlineFault('multinode cleanup incomplete: ' + '; '.join(self.cleanup_errors))
