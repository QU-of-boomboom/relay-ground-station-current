"""Arm bounded PL validity and read hardware alarm bits; no PS alarm decision."""
from quality_reference import integer
from alarm_snapshot_client import SnapshotAccessError

class UnifiedAlarmClient:
    def __init__(self,transport,*,bad_hold_ms=2,good_hold_ms=2):
        integer(bad_hold_ms,1,65535);integer(good_hold_ms,1,65535)
        self.transport=transport;self.holds=(good_hold_ms<<16)|bad_hold_ms
        self.slots=set();self.closed=False
        if self.read(0)!=0x47554133 or self.read(4)!=1:
            raise SnapshotAccessError('unified PL alarm ABI missing')
        if self.read(0x1c):raise SnapshotAccessError('unified alarm has uncleared hardware error')

    def read(self,offset):
        value=self.transport.alarm_read32(offset)
        integer(value,0,0xffffffff)
        return value

    def write(self,offset,value):self.transport.alarm_write32(offset,value)

    def prepare(self,*,slot,tag,required,horizon_ns):
        if self.closed:raise SnapshotAccessError('unified alarm client closed')
        integer(slot,0,3);integer(tag,1,0xffffffff);integer(required,1,7)
        if not required&1:raise ValueError('PDR required')
        integer(horizon_ns,1_000_000,65535_999_999)
        ttl=horizon_ns//1_000_000
        # This deadline starts in PL BEFORE the host captures prepare_horizon time.
        # Fractional ms is rounded down: the hardware may expire early, never late.
        self.write(8,slot);self.write(0xc,ttl);self.write(0x10,self.holds)
        self.write(0x14,required);self.slots.add(slot);self.write(0x18,tag)
        if self.read(0x18)!=tag or self.read(0x1c):
            raise SnapshotAccessError('unified alarm arm rejected; no quality submit')

    def snapshot(self,slot):
        integer(slot,0,3)
        if self.closed:raise SnapshotAccessError('unified alarm client closed')
        word=self.read(0x20+slot*4);state=word&7
        if state>4:raise SnapshotAccessError('invalid unified hardware state')
        return dict(source='FPGA_UNIFIED_PDR_RTT_AOI',raw=word,
            valid=bool(word&16),alarm=bool(word&8) if word&16 else None,
            state=('UNAVAILABLE','CLEAR','PENDING_BAD','ALARM','RECOVERING')[state],
            condition=('UNAVAILABLE','BAD','BAND','GOOD')[(word>>5)&3],
            missing=(word>>7)&7,remaining_ms=word>>16,required=(word>>13)&7,
            pending=bool(word&(1<<12)),slot=slot)

    def cancel(self,slot):
        integer(slot,0,3);self.write(8,slot);self.write(0x1c,1)
        if self.read(0x20+slot*4)&16:raise SnapshotAccessError('unified alarm stop not confirmed')
        self.slots.discard(slot)

    def close(self):
        if self.closed:return
        errors=[]
        for slot in tuple(self.slots):
            try:self.cancel(slot)
            except BaseException as exc:errors.append(str(exc))
        self.closed=True
        if errors:raise SnapshotAccessError('; '.join(errors))
