"""Coherent snapshot client; caller supplies exclusive ordered transport and reset guard."""
from alarm_snapshot import decode_snapshot

class SnapshotAccessError(RuntimeError):pass
class SnapshotUnavailable(SnapshotAccessError):pass

class AlarmSnapshotClient:
    def __init__(self,transport,base,attempts=32):
        if type(base) is not int or base<0 or base%4 or base>0xffffffff-0xa0:raise ValueError('base')
        if type(attempts) is not int or attempts<1:raise ValueError('attempts')
        self.transport=transport;self.base=base;self.attempts=attempts
        self.epoch=transport.reset_epoch();self.token=0;self.stopped=False

    def _guard(self):
        if self.transport.reset_epoch()!=self.epoch:raise SnapshotAccessError('reset epoch changed')

    def _read(self,offset):
        if getattr(self.transport,'native_guarded',False):
            return self.transport.guarded_reads([self.base+offset],self.epoch)[0]
        self._guard();value=self.transport.read32(self.base+offset);self._guard()
        if type(value) is not int or not 0<=value<=0xffffffff:raise SnapshotAccessError('invalid read32')
        return value

    def _write(self,offset,value):
        if getattr(self.transport,'native_guarded',False):
            self.transport.guarded_writes([self.base+offset],[value],self.epoch);return
        self._guard();self.transport.write32(self.base+offset,value);self._guard()

    def read_snapshot(self):
        if self.stopped:raise SnapshotAccessError('client stopped; explicit recovery required')
        try:
            if self._read(0)!=0x47534131 or self._read(4)!=0x10019:raise SnapshotAccessError('identity/ABI')
            if self._read(16):raise SnapshotAccessError('sticky error')
            for _ in range(self.attempts):
                status=self._read(8)
                if status&~1:raise SnapshotAccessError('busy or reserved status')
                if status==1:break
            else:raise SnapshotUnavailable('no snapshot within bounded poll budget')
            if self.token==0xffffffff:raise SnapshotAccessError('token exhausted')
            self.token+=1;self._write(0x14,self.token)
            self._check_locked()
            words=(self.transport.guarded_reads([self.base+0x40+4*i for i in range(25)],self.epoch)
                   if getattr(self.transport,'native_guarded',False) else [self._read(0x40+4*i) for i in range(25)])
            result=decode_snapshot(sum(word<<(32*i) for i,word in enumerate(words)))
            self._check_locked()
            self._write(0x18,self.token)
            if self._read(8)&2 or self._read(12) or self._read(16):raise SnapshotAccessError('release failed')
            return result
        except SnapshotUnavailable:raise
        except Exception:
            self.stopped=True
            raise

    def _check_locked(self):
        if self._read(8)!=3 or self._read(12)!=self.token or self._read(16):
            raise SnapshotAccessError('capture revoked or ownership/error mismatch')
