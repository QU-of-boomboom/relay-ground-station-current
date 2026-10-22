"""Single-owner fair UDP acquisition and bounded PL commits for up to four nodes."""
from pathlib import Path
import threading
import time

from ledger_station import Journal
from quality_reference import integer
from remote_round_protocol import RemoteFault
from remote_station_lane import RemoteStationLane


class RemoteFleet:
    def __init__(self,directory,lanes,*,count,period_ns,retry_interval_ns,clock_ns=time.monotonic_ns,drain_limit=256):
        if type(lanes) is not dict or not 1<=len(lanes)<=4:raise ValueError('one to four explicit slot lanes required')
        if any(type(slot) is not int or not 0<=slot<4 or not isinstance(lane,RemoteStationLane) for slot,lane in lanes.items()):
            raise ValueError('validated slot lanes required')
        integer(count,1,64);integer(period_ns,1,2**63-1);integer(retry_interval_ns,1,2**63-1)
        integer(drain_limit,1,65536)
        if not callable(clock_ns):raise ValueError('monotonic clock required')
        if len({lane.host.node for lane in lanes.values()})!=len(lanes):raise ValueError('unique node per slot')
        if len({lane.host.key for lane in lanes.values()})!=len(lanes):raise ValueError('distinct node keys required')
        if len({lane.domain for lane in lanes.values()})!=1:raise ValueError('shared host clock domain required')
        if any(lane.owner!=threading.get_ident() or lane.host.active is not None or lane.stopped or
               count>lane.station.engine.capacity or retry_interval_ns>=lane.host.facts_timeout for lane in lanes.values()):
            raise ValueError('fresh owner lanes and bounded profile required')
        self.lanes=dict(lanes);self.order=tuple(lanes);self.clock=clock_ns
        self.count,self.period,self.retry_interval,self.drain_limit=count,period_ns,retry_interval_ns,drain_limit
        self.owner=threading.get_ident();self.busy=self.closed=self.failed=False
        self.cursor=self.polls=0;self.last_now=-1;self.failures={};self.cleanup_errors=[]
        self.next_due={slot:0 for slot in lanes};self.retry_due={slot:0 for slot in lanes}
        self.directory=Path(directory);self.lock=self.journal=None
        try:
            self.lock=(self.directory/'fleet.lock').open('xb')
            if any(p.name!='fleet.lock' for p in self.directory.iterdir()):raise ValueError('new empty fleet generation required')
            self.journal=Journal(self.directory/'fleet.jsonl')
            self.journal.append('header',dict(schema=1,slots=list(self.order),count=count,period_ns=period_ns,
                retry_interval_ns=retry_interval_ns,drain_limit=drain_limit,deadline_origin='host_grant',board_verified=False))
        except BaseException:self._stop_all('FLEET_START_FAILED',True);raise

    def _owner(self):
        if threading.get_ident()!=self.owner or self.busy:raise RemoteFault('fleet requires idle owner thread')

    def _now(self):
        now=self.clock();integer(now,max(0,self.last_now),2**63-1);self.last_now=now;return now

    def _source_failed(self,slot,error):
        lane=self.lanes[slot]
        self.failures[slot]=str(error)
        # A network source timeout does not grant authority to stop a healthy
        # peer or reset the shared hardware. Unknown PL completion is handled globally.
        lane.stop('REMOTE_SOURCE_FAILED')
        self.journal.append('source_failed',dict(slot=slot,reason=str(error),now_ns=self._now()))

    def poll(self):
        self._owner()
        if self.closed:raise RemoteFault('fleet generation stopped')
        self.busy=True
        try:
            now=self._now();order=self.order[self.cursor:]+self.order[:self.cursor]
            self.journal.append('poll_begin',dict(poll=self.polls,order=order,now_ns=now))
            # First issue due grants and drain EVERY active socket before any
            # lane is allowed to perform a potentially slow PL commit batch.
            for slot in order:
                if slot in self.failures:continue
                lane=self.lanes[slot];host=lane.host
                try:
                    complete=host.active is None or (host.active.closed is not None and
                        lane.imported_round==host.active.context.round and not lane.station.engine.pending)
                    now=self._now()
                    if complete and now>=self.next_due[slot]:
                        integer(now,0,2**63-1-self.period)
                        lane.begin(self.count)
                        self.next_due[slot]=host.active.started+self.period
                        self.retry_due[slot]=host.active.started+self.retry_interval
                    if host.active is not None and host.active.closed is None:
                        host.pump(self.drain_limit)
                        now=self._now()
                        if host.active.mask is None and now>=self.retry_due[slot] and now<host.active.timeout and host.retries<3:
                            host.retry_facts();self.retry_due[slot]=min(host.active.timeout,now+self.retry_interval)
                except RemoteFault as error:self._source_failed(slot,error)
            statuses={}
            for slot in order:
                if slot in self.failures:
                    statuses[slot]=dict(active=False,source_failed=self.failures[slot],committed=0)
                    continue
                try:statuses[slot]=self.lanes[slot].poll(self.drain_limit)
                except RemoteFault as error:
                    self._source_failed(slot,error)
                    statuses[slot]=dict(active=False,source_failed=self.failures[slot],committed=0)
            self.journal.append('poll_result',dict(poll=self.polls,committed={slot:row['committed'] for slot,row in statuses.items()},
                source_failed=sorted(self.failures),now_ns=self._now()))
            self.polls+=1;self.cursor=(self.cursor+1)%len(self.order)
            if len(self.failures)==len(self.lanes):self._stop_all('ALL_REMOTE_SOURCES_FAILED',True)
            return dict(poll=self.polls,order=order,nodes=statuses,source_failed=dict(self.failures),
                        stopped=self.closed,board_verified=False)
        except BaseException:
            self._stop_all('FLEET_OPERATION_FAILED',True)
            raise
        finally:self.busy=False

    def _stop_all(self,reason,failed):
        self.closed=True;self.failed|=failed
        # Revoke all qualification before attempting even the first file close.
        for lane in self.lanes.values():
            lane.station.engine.stop(reason);lane.timing.stop(reason)
        for lane in self.lanes.values():
            try:lane.stop(reason)
            except BaseException as error:self.cleanup_errors.append(type(error).__name__)
        if self.journal is not None:
            journal,self.journal=self.journal,None
            try:journal.append('stop',dict(reason=reason,failed=self.failed,source_failed=sorted(self.failures)))
            except BaseException as error:self.cleanup_errors.append(type(error).__name__)
            try:journal.close()
            except BaseException as error:self.cleanup_errors.append(type(error).__name__)
        if self.lock is not None:
            lock,self.lock=self.lock,None
            try:lock.close();(self.directory/'fleet.lock').unlink()
            except BaseException as error:self.cleanup_errors.append(type(error).__name__)

    def close(self,reason='NORMAL_STOP'):
        self._owner()
        if not self.closed:self._stop_all(reason,False)
        if self.cleanup_errors:raise RemoteFault('fleet cleanup incomplete: '+','.join(self.cleanup_errors))
