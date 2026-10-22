"""Bounded ordered register process and combined PS/slot reset guard."""
import queue
import secrets
import subprocess
import threading
from alarm_snapshot_client import SnapshotAccessError
from monitor_control_client import GuardedLocalTransport


class RegisterProcess:
    def __init__(self, executable, mapping, *, file_test=False, timeout=2.0):
        if type(timeout) not in (int, float) or not 0 < timeout <= 60:
            raise ValueError('finite timeout in (0,60] required')
        self.timeout = timeout
        self.stopped = False
        self.hardware_backend = not file_test
        self.lock = threading.Lock()
        self.responses = queue.Queue(maxsize=4)
        self.process = subprocess.Popen([str(executable), '--file' if file_test else '--uio', str(mapping)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        bufsize=0)
        self.reader = threading.Thread(target=self._read_lines, daemon=True)
        self.reader.start()
        try:
            backend = 'FILE' if file_test else 'UIO'
            hello = self._response()
            if hello not in (f'READY 1 {backend}', f'READY 2 {backend}'):
                raise SnapshotAccessError('register helper identity or backend mismatch')
            self.protocol_version = int(hello.split()[1])
        except Exception:
            self._stop()
            raise

    def _read_lines(self):
        try:
            while True:
                data = self.process.stdout.readline(129)
                if not data or len(data) > 128 or not data.endswith(b'\n'):
                    self.responses.put_nowait(None)
                    return
                self.responses.put_nowait(data.decode('ascii').rstrip('\n'))
        except Exception:
            try: self.responses.put_nowait(None)
            except queue.Full: pass

    def _response(self):
        try: value = self.responses.get(timeout=self.timeout)
        except queue.Empty as error: raise SnapshotAccessError('MMIO completion unknown: helper timeout') from error
        if value is None: raise SnapshotAccessError('MMIO completion unknown: helper stopped')
        return value

    def _stop(self):
        self.stopped = True
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=1)
        for stream in (self.process.stdin, self.process.stdout):
            if stream is not None: stream.close()

    def _exchange(self, request):
        with self.lock:
            if self.stopped: raise SnapshotAccessError('register helper lifetime ended')
            try:
                self.process.stdin.write((request + '\n').encode('ascii'))
                self.process.stdin.flush()
                return self._response()
            except Exception:
                self._stop()
                raise

    def read32(self, address):
        self._address(address)
        response = self._exchange(f'READ {address}')
        try:
            if not response.startswith('VALUE '): raise ValueError('read tag')
            text = response[6:]
            if not text.isascii() or not text.isdecimal(): raise ValueError('read integer')
            value = int(text)
            if not 0 <= value <= 0xffffffff: raise ValueError('read range')
            return value
        except Exception as error:
            self._stop()
            raise SnapshotAccessError('malformed register response') from error

    def write32(self, address, value):
        self._address(address)
        if type(value) is not int or not 0 <= value <= 0xffffffff: raise ValueError('word value')
        if self._exchange(f'WRITE {address} {value}') != 'WRITTEN':
            self._stop()
            raise SnapshotAccessError('write completion unknown')

    def read32_many(self, addresses):
        addresses = _read_addresses(addresses)
        if self.protocol_version == 1:
            return tuple(self.read32(address) for address in addresses)
        response = self._exchange('READS ' + str(len(addresses)) + ' ' + ' '.join(map(str, addresses)))
        try:
            fields = response.split(' ')
            if len(fields) != len(addresses) + 2 or fields[:2] != ['VALUES', str(len(addresses))]:
                raise ValueError('batch read shape')
            if any(not word.isascii() or not word.isdecimal() for word in fields[2:]):
                raise ValueError('batch read integer')
            values = tuple(map(int, fields[2:]))
            if any(value > 0xffffffff for value in values): raise ValueError('batch read range')
            return values
        except Exception as error:
            self._stop()
            raise SnapshotAccessError('malformed batch register response') from error

    @staticmethod
    def _address(address):
        if type(address) is not int or not 0 <= address <= 4092 or address % 4: raise ValueError('register offset')

    def close(self):
        if not self.stopped:
            try:
                if self._exchange('CLOSE') != 'CLOSED': raise SnapshotAccessError('helper close response')
            finally: self._stop()


def _read_addresses(addresses):
    if type(addresses) not in (tuple, list) or not 1 <= len(addresses) <= 8:
        raise ValueError('one to eight explicit register addresses required')
    for address in addresses: RegisterProcess._address(address)
    return tuple(addresses)


def _ordered_reads(raw, addresses):
    """The scalar fallback preserves reference transports without batch support."""
    addresses = _read_addresses(addresses)
    batch = getattr(raw, 'read32_many', None)
    values = batch(addresses) if callable(batch) else tuple(raw.read32(a) for a in addresses)
    if type(values) not in (tuple, list) or len(values) != len(addresses) or any(
            type(v) is not int or not 0 <= v <= 0xffffffff for v in values):
        raise SnapshotAccessError('invalid ordered register words')
    return tuple(values)


class PhysicalBusLease:
    """Claim a new hardware-visible software lifetime under the raw process lock."""
    def __init__(self, raw, token=None):
        self.raw=raw
        self.token=secrets.randbits(64) if token is None else token
        if type(self.token) is not int or not 1 <= self.token <= 0xffffffffffffffff:
            raise ValueError('nonzero 64-bit session token')
        self.stopped=False
        try:
            if raw.read32(0xfc0)!=0x47534d34 or raw.read32(0xfc4)!=0x10004:
                raise SnapshotAccessError('session lease ABI missing')
            before=self._guard()
            old=raw.read32(0xfc8) | (raw.read32(0xfcc)<<32)
            if old==self.token:raise SnapshotAccessError('session token must not be reused')
            if raw.read32(0xfd4):raise SnapshotAccessError('lease bank sticky error')
            raw.write32(0xfd8,self.token & 0xffffffff)
            raw.write32(0xfdc,self.token >> 32)
            raw.write32(0xfd0,1)
            self.verify_lifetime()
            if self._guard()!=before:raise SnapshotAccessError('reset while claiming session')
            self.verify_lifetime()
        except Exception:
            self.stopped=True
            raise

    def _guard(self):
        raw=self.raw
        identity,abi,before,status,after=_ordered_reads(raw,(0xf00,0xf0c,0xf08,0xf04,0xf08))
        if identity!=0x47535431 or abi!=0x10001:
            raise SnapshotAccessError('physical guard ABI missing')
        if before!=after or status & ~7 or status & 3 != 3:
            raise SnapshotAccessError('physical backend unavailable for lease')
        return before

    def verify_lifetime(self):
        if self.stopped:raise SnapshotAccessError('physical session ended')
        try:
            low,high,again,error=_ordered_reads(self.raw,(0xfc8,0xfcc,0xfc8,0xfd4))
            if low!=again or (low | (high<<32))!=self.token or error:
                raise SnapshotAccessError('PS reset or software owner changed')
        except Exception:
            self.stopped=True
            raise

    def read32(self,address):
        if self.stopped:raise SnapshotAccessError('physical session ended')
        return self.raw.read32(address)

    def write32(self,address,value):
        if self.stopped:raise SnapshotAccessError('physical session ended')
        return self.raw.write32(address,value)

    def read32_many(self,addresses):
        if self.stopped:raise SnapshotAccessError('physical session ended')
        return _ordered_reads(self.raw,addresses)


class PhysicalSlotTransport:
    """A slot lifetime requires BOTH outer PS guard and the slot guard to match."""
    def __init__(self, raw, slot):
        if type(slot) is not int or not 0 <= slot < 4: raise ValueError('slot')
        if not callable(getattr(raw,'verify_lifetime',None)):raise ValueError('claimed physical session required')
        self.raw = raw
        self.slot = slot
        self.local = GuardedLocalTransport(raw, slot * 0x400)
        self.native_guarded=bool(getattr(getattr(raw,'raw',None),'native_guarded',False))

    def _outer_epoch(self):
        self.raw.verify_lifetime()
        identity,abi,before,status,after=_ordered_reads(self.raw,(0xf00,0xf0c,0xf08,0xf04,0xf08))
        if identity != 0x47535431 or abi != 0x10001:
            raise SnapshotAccessError('four-slot physical guard ABI missing')
        if before != after or status & ~7 or status & 3 != 3:
            raise SnapshotAccessError('physical backend unavailable/reset/sticky fault')
        self.raw.verify_lifetime()
        return before

    def reset_epoch(self):
        if self.native_guarded:
            if self.raw.stopped:raise SnapshotAccessError('physical session ended')
            try:return self.raw.raw.slot_epoch(self.slot,self.raw.token)
            except Exception:
                self.raw.stopped=True
                raise
        before = self._outer_epoch()
        local = self.local.reset_epoch()
        after = self._outer_epoch()
        if before != after: raise SnapshotAccessError('outer reset while reading slot guard')
        return before, local

    def guarded_reads(self,offsets,epoch):
        return self._guarded(offsets,epoch)

    def guarded_writes(self,offsets,values,epoch):
        return self._guarded(offsets,epoch,values)

    def _guarded(self,offsets,epoch,values=None):
        if not self.native_guarded or self.raw.stopped:raise SnapshotAccessError('native physical session unavailable')
        try:return self.raw.raw.guarded_transfer(self.slot,self.raw.token,epoch,offsets,values)
        except Exception:
            self.raw.stopped=True
            raise

    def _offset(self, offset):
        if type(offset) is not int or not 0 <= offset < 1024 or offset % 4: raise ValueError('slot register offset')
        if self.slot == 3 and offset >= 0x2c0: raise ValueError('reserved unified alarm, global guard, quality service or lease window')

    def read32(self, offset):
        self._offset(offset)
        return self.local.read32(offset)

    def write32(self, offset, value):
        self._offset(offset)
        return self.local.write32(offset, value)


class PhysicalQualityTransport:
    """The shared PL service at 0xf40; uses the same claimed PS/PL lifetime."""
    def __init__(self, raw):
        self.raw=raw
        # Reuse the exact outer guard/lease checks, with no lane-zero ownership.
        self.guard=PhysicalSlotTransport(raw,0)

    def reset_epoch(self):
        return self.guard._outer_epoch()

    @staticmethod
    def _offset(offset):
        if type(offset) is not int or not 0<=offset<=0x7c or offset%4:
            raise ValueError('shared quality service local offset')

    def read32(self,offset):
        self._offset(offset)
        return self.raw.read32(0xf40+offset)

    def write32(self,offset,value):
        self._offset(offset)
        return self.raw.write32(0xf40+offset,value)

    def alarm_read32(self,offset):
        if type(offset) is not int or not 0<=offset<=0x3c or offset%4:
            raise ValueError('unified alarm register offset')
        return self.raw.read32(0xec0+offset)

    def alarm_write32(self,offset,value):
        if type(offset) is not int or not 0<=offset<=0x3c or offset%4:
            raise ValueError('unified alarm register offset')
        return self.raw.write32(0xec0+offset,value)
