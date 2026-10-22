"""Bounded, single-owner client for the shared hardware quality pipeline."""
from dataclasses import dataclass
import threading
import time

from alarm_snapshot_client import SnapshotAccessError
from link_quality_reference import evaluate
from quality_horizon import prepare_horizon
from quality_reference import integer
from quality_relay import QualityEvent


@dataclass(frozen=True)
class HardwareQuality:
    horizon: object
    completed_ns: int
    condition: int
    missing: int
    pdr: int
    rtt_condition: int
    rtt_reason: int
    aoi_condition: int
    aoi_reason: int
    pl_time_ms: int
    pl_generation: int


class LinkServiceClient:
    def __init__(self,transport,*,clock_domain,clock_ns=time.monotonic_ns,poll_limit=1000):
        if type(clock_domain) is not str or not clock_domain or not callable(clock_ns):
            raise ValueError('explicit host clock required')
        integer(poll_limit,1,100000)
        self.transport,self.domain,self.clock=transport,clock_domain,clock_ns
        self.poll_limit=poll_limit
        self.owner=threading.get_ident();self.busy=self.stopped=False
        self.epoch=transport.reset_epoch()
        self.unified=None
        try:
            abi=self._read(4)
            if self._read(0)!=0x47535134 or abi not in (0x10019,0x1001a):
                raise SnapshotAccessError('shared PL quality service ABI missing')
            if self._read(8) not in (0,16) or self._read(0x0c) or self._read(0x7c):
                raise SnapshotAccessError('quality service not clean; no automatic recovery')
            self.next_tag=self._read(0x74)+1
            if abi==0x1001a:
                from unified_alarm_client import UnifiedAlarmClient
                self.unified=UnifiedAlarmClient(transport)
            self._guard()
        except BaseException:
            self.stopped=True
            raise

    def _guard(self):
        if self.transport.reset_epoch()!=self.epoch:
            raise SnapshotAccessError('quality service physical lifetime changed')

    def _read(self,address):
        value=self.transport.read32(address)
        if type(value) is not int or not 0<=value<=0xffffffff:
            raise SnapshotAccessError('quality service read32 result')
        return value

    def transact(self,station,timing,*,slot,required,horizon_ns):
        if threading.get_ident()!=self.owner or self.busy:
            raise SnapshotAccessError('single-owner nonreentrant quality transaction required')
        if self.stopped:raise SnapshotAccessError('quality service client stopped')
        self.busy=True
        try:
            if self.unified is not None:
                self._guard()
                self.unified.prepare(slot=slot,tag=self.next_tag,required=required,horizon_ns=horizon_ns)
            started=self.clock()
            request=prepare_horizon(station,timing,slot=slot,tag=self.next_tag,required=required,
                started_ns=started,horizon_ns=horizon_ns,clock_domain=self.domain)
            self.next_tag+=1
            previous=started
            def deadline_check():
                nonlocal previous
                now=self.clock();integer(now,previous,request.deadline_ns-1);previous=now
                return now
            def read(address):
                deadline_check();value=self._read(address);deadline_check();return value
            def write(address,value):
                deadline_check();self.transport.write32(address,value);deadline_check()
            self._guard();deadline_check()
            if read(8) not in (0,16) or read(0x0c) or read(0x7c):
                raise SnapshotAccessError('quality service dirty before request')
            for index,word in enumerate(request.words()):write(0x10+index*4,word)
            if read(0x7c)!=0x1ffffff:raise SnapshotAccessError('quality shadow incomplete')
            self._guard();deadline_check()
            write(8,1)
            for _ in range(self.poll_limit):
                status=read(8)
                if status&~31 or status&8:raise SnapshotAccessError('quality service protocol error')
                if status&16:raise SnapshotAccessError('PL quality sources revoked')
                if status==2:break
                if status!=1:raise SnapshotAccessError('quality request disappeared')
            else:raise TimeoutError('quality service completion unknown; no retry')
            words=[]
            for index in range(12):
                write(0x74,index);words.append(read(0x78))
            if words[0]!=request.tag or tuple(words[2:9])!=request.words()[2:9]:
                raise SnapshotAccessError('quality result identity/tag mismatch')
            bits=words[1]
            if bits>>16 or words[11]>>8:raise SnapshotAccessError('revoked or malformed quality result')
            pdr=(bits>>14)&3
            if pdr and (not request.pdr_available or pdr!=request.expected_pdr):
                raise SnapshotAccessError('hardware PDR contradicts confirmed counts/source qualification')
            expected=evaluate(request.tag,pdr,required,request.rtt,request.aoi)
            expected_bits=(expected['condition']|expected['missing']<<2|int(expected['invalid'])<<5|
                expected['rtt_condition']<<6|expected['rtt_reason']<<8|
                expected['aoi_condition']<<10|expected['aoi_reason']<<12|pdr<<14)
            if bits!=expected_bits:raise SnapshotAccessError('hardware quality disagrees with interval contract')
            if read(8)!=2 or read(0x0c):raise SnapshotAccessError('late PL quality revocation/error')
            # Guard and source checks are part of the same bounded interval,
            # including their actual MMIO/IPC latency.
            station.client.check_active();self._guard()
            request.check_completion(deadline_check(),station,timing)
            write(8,2)
            if read(8)!=0 or read(0x0c):raise SnapshotAccessError('quality release/revocation unknown')
            station.client.check_active();self._guard()
            completed=deadline_check();request.check_completion(completed,station,timing)
            return HardwareQuality(request,completed,bits&3,(bits>>2)&7,pdr,
                (bits>>6)&3,(bits>>8)&3,(bits>>10)&3,(bits>>12)&3,
                words[9]|words[10]<<32,words[11])
        except BaseException:
            self.stopped=True
            station.engine.stop('PL_QUALITY_TRANSACTION_FAILED')
            timing.stop('PL_QUALITY_TRANSACTION_FAILED')
            raise
        finally:self.busy=False

    def unified_snapshot(self,slot):
        self._guard()
        return self.unified.snapshot(slot) if self.unified is not None else None

    def cancel_unified(self):
        if self.unified is not None:
            self._guard()
            for slot in tuple(self.unified.slots):self.unified.cancel(slot)

    def close(self):
        try:
            if self.unified is not None:
                self._guard();self.unified.close()
        finally:self.stopped=True


class HardwareQualityAdapter:
    """Same coordinator interface as the software adapter, with real PL results."""
    def __init__(self,client,station,timing,*,slot,required,horizon_ns,direct_path):
        if not isinstance(client,LinkServiceClient) or type(direct_path) is not bool:
            raise ValueError('quality service client and explicit path required')
        integer(slot,0,3);integer(required,1,7);integer(horizon_ns,1,2**63-1)
        if not required&1:raise ValueError('PDR required')
        self.client,self.station,self.timing=client,station,timing
        self.slot,self.required,self.horizon=slot,required,horizon_ns
        self.direct=direct_path;self.settings=station.settings
        self.previous=self.signature=None

    def sample(self):
        if self.station.settings!=self.settings:
            self.client.stopped=True
            raise SnapshotAccessError('hardware quality adapter configuration changed')
        result=self.client.transact(self.station,self.timing,slot=self.slot,required=self.required,horizon_ns=self.horizon)
        self.last_result=result
        signature=(self.station.confirmed,tuple(self.station.ring),
            tuple(self.timing.samples) if self.required&2 else (),
            (self.timing.highest_state,self.timing.generation) if self.required&4 else (),result.condition,self.direct)
        if signature!=self.signature:
            request=result.horizon;s=self.settings
            self.previous=QualityEvent(s.node,s.session,s.epoch,s.revision,request.tag,
                result.completed_ns,request.deadline_ns,self.client.domain,
                ('UNAVAILABLE','BAD','BAND','GOOD')[result.condition],self.direct)
            self.signature=signature
        return self.previous,result.completed_ns
