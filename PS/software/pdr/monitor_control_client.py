"""Atomic monitor input client over an explicit exclusive ordered local transport."""
from typing import Optional
from dataclasses import dataclass
from alarm_snapshot_client import SnapshotAccessError

@dataclass(frozen=True)
class ControlResult:
    accepted: bool
    receipt: int

@dataclass(frozen=True)
class SettleResult:
    accepted: bool
    bridge_code: int
    executor_code: int
    cache_receipt: int
    response: int
    count: Optional[int]
    delivered: Optional[int]
    next_index: Optional[int]

class MonitorControlClient:
    def __init__(self,transport,base,*,poll_limit=1000,window_size=64):
        if type(base) is not int or base<0 or base%4 or base>0xffffffff-0x9c:raise ValueError('base')
        if type(poll_limit) is not int or poll_limit<1:raise ValueError('poll limit')
        if type(window_size) is not int or not 1<=window_size<=256:raise ValueError('window size')
        self.transport=transport;self.base=base;self.poll_limit=poll_limit
        self.epoch=transport.reset_epoch();self.stopped=False
        self.window_size=window_size
    def _guard(self):
        if self.transport.reset_epoch()!=self.epoch:raise SnapshotAccessError('reset during monitor command')
    def check_active(self):
        """Poll the reset guard while no statistics command is being sent."""
        if self.stopped:raise SnapshotAccessError('control client stopped')
        try:self._guard()
        except Exception:
            self.stopped=True
            raise
    def _read(self,offset):
        if getattr(self.transport,'native_guarded',False):
            return self.transport.guarded_reads([self.base+offset],self.epoch)[0]
        self._guard();v=self.transport.read32(self.base+offset);self._guard()
        if type(v) is not int or not 0<=v<=0xffffffff:raise SnapshotAccessError('read32 result')
        return v
    def _write(self,offset,value):
        if getattr(self.transport,'native_guarded',False):
            self.transport.guarded_writes([self.base+offset],[value],self.epoch);return
        self._guard();self.transport.write32(self.base+offset,value);self._guard()

    def _reads(self,offsets):
        if getattr(self.transport,'native_guarded',False):
            return self.transport.guarded_reads([self.base+o for o in offsets],self.epoch)
        return tuple(self._read(o) for o in offsets)
    def _transact(self,kind,raw,width):
        if self.stopped:raise SnapshotAccessError('control client stopped')
        if type(raw) is not int or not 0<=raw<1<<width:raise ValueError('payload width')
        try:
            if self._read(0)!=0x47534331:raise SnapshotAccessError('control identity')
            abi=self._read(4)
            if abi not in (0x1000c,0x2000c) or (kind==3 and abi!=0x2000c):raise SnapshotAccessError('control ABI/capability')
            if self._read(8) not in (0,2,6) or self._read(20):raise SnapshotAccessError('busy or protocol error')
            self._write(0x1c,1)
            if getattr(self.transport,'native_guarded',False):
                self.transport.guarded_writes([self.base+0x40+4*i for i in range(12)],
                                             [(raw>>(32*i))&0xffffffff for i in range(12)],self.epoch)
            else:
                for i in range(12):self._write(0x40+4*i,(raw>>(32*i))&0xffffffff)
            if self._read(24)!=0xfff:raise SnapshotAccessError('incomplete input shadow')
            self._write(0x0c,kind)
            for _ in range(self.poll_limit):
                status=self._read(8)
                if status&~7:raise SnapshotAccessError('control protocol error')
                if status in (2,6):break
                if status!=1:raise SnapshotAccessError('command disappeared')
            else:raise TimeoutError('monitor command timeout; completion unknown')
            code=self._read(16)
            success=bool(status&4)
            if kind==1:
                if code not in (0,1) or success!=(code==0):raise SnapshotAccessError('configuration receipt')
            elif kind==2:
                if not 1<=code<=7 or success!=(code==1):raise SnapshotAccessError('evidence receipt')
            else:
                words=self._reads([0x80+4*i for i in range(8)])
                response=sum(w<<(32*i) for i,w in enumerate(words))
                bridge=code>>16;executor=(code>>8)&255;cache=code&255
                if bridge>4 or executor>9 or cache>7 or success!=(code in (0,1)):
                    raise SnapshotAccessError('settlement completion code')
                if bridge:
                    if executor or cache or response:raise SnapshotAccessError('bridge reject carried stale response')
                    result=SettleResult(False,bridge,0,0,0,None,None,None)
                else:
                    flags=words[0]>>24;count=words[4]&511;delivered=(words[4]>>9)&511
                    if (words[0]&65535)!=(raw>>16)&65535 or (words[0]>>16)&255!=executor or flags&~7 or words[4]>>18:
                        raise SnapshotAccessError('settlement response header')
                    if delivered>count or count>self.window_size or bool(flags&2)!=bool(count) or bool(flags&4)!=(count==self.window_size):
                        raise SnapshotAccessError('settlement response counters')
                    if executor<=1:
                        if not flags&1 or (response>>32)&((1<<64)-1)!=(raw>>32)&((1<<64)-1) or words[5]!=(raw>>96)&0xffffffff or response>>192!=(raw>>128)&((1<<64)-1):
                            raise SnapshotAccessError('settlement identity')
                        if raw&255==2 and words[3]!=((raw>>192)&0xffffffff)+1:
                            raise SnapshotAccessError('settlement index')
                        if raw&255==1 and executor==0 and (words[3] or count):
                            raise SnapshotAccessError('new statistics epoch is not empty')
                    if executor==0 and raw&255 in (1,2):
                        if cache==0:raise SnapshotAccessError('new count never reached evidence cache')
                    elif cache:raise SnapshotAccessError('read/rejected transaction refreshed evidence')
                    result=SettleResult(success,0,executor,cache,response,count,delivered,words[3])
                if self._read(20):raise SnapshotAccessError('late settlement protocol error')
                return result
            if self._read(20):raise SnapshotAccessError('late control protocol error')
            return ControlResult(success,code)
        except Exception:
            self.stopped=True;raise
    def configure(self,raw):return self._transact(1,raw,326)
    def submit(self,raw):return self._transact(2,raw,372)
    def settle(self,raw):return self._transact(3,raw,256)

class GuardedLocalTransport:
    """Read the actual guard ABI; raw owns ordered bounded accesses and exclusivity.

    The guard and clients share a base-relative address space. A PS/system reset
    terminates the whole transport lifetime; epoch only detects backend resets.
    """
    def __init__(self,raw,base=0):
        if type(base) is not int or base<0 or base%4 or base>0xffffffff-0x20c:raise ValueError('base')
        self.raw=raw;self.base=base
    def read32(self,a):return self.raw.read32(self.base+a)
    def write32(self,a,v):self.raw.write32(self.base+a,v)
    def reset_epoch(self):
        if self.read32(0x200)!=0x47535431 or self.read32(0x20c)!=0x10001:
            raise SnapshotAccessError('guard identity/ABI')
        before=self.read32(0x208);status=self.read32(0x204);after=self.read32(0x208)
        if before!=after or status&~7 or status&3!=3:
            raise SnapshotAccessError('guard unavailable, reset changed, or sticky fault')
        return before
