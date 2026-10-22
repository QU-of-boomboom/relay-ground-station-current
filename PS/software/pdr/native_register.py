"""Single-thread native MMIO, same UIO identity/lock/barriers as pipe helper.

No timeout can recover a CPU stalled in a device bus access. Transaction clocks
and the physical guards remain mandatory above this transport.
"""
import ctypes as C
import hashlib
import os
from pathlib import Path
import threading


class EventBatchError(RuntimeError):
    """Retain a confirmed prefix when a later event has unknown completion."""
    def __init__(self, message, receipt):
        super().__init__(message)
        self.receipt = receipt


class NativeRegister:
    def __init__(self, library, device, *, sha256, file_backend=False):
        path = Path(library).resolve(strict=True)
        if len(sha256) != 64 or hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
            raise ValueError('native MMIO library SHA mismatch')
        self.owner = (os.getpid(), threading.get_ident())
        self.handle = C.c_void_p()
        self.failed = False
        # Retain the GIL; no asynchronous Python activity can interleave MMIO.
        self.lib = C.PyDLL(str(path))
        self.lib.gs_mmio_abi.restype = C.c_uint
        if self.lib.gs_mmio_abi() != 1:
            raise ValueError('native MMIO ABI mismatch')
        self.native_guarded=hasattr(self.lib,'gs_mmio_guarded_abi')
        self.native_event_batch=hasattr(self.lib,'gs_mmio_event_batch_abi')
        if self.native_event_batch:
            if self.lib.gs_mmio_event_batch_abi()!=1:raise ValueError('event batch native ABI mismatch')
            self.lib.gs_mmio_event_batch.argtypes=[C.c_void_p,C.c_uint,C.c_uint64,C.c_uint32,C.c_uint32,
                C.POINTER(C.c_uint32),C.c_uint,C.c_uint64,C.POINTER(C.c_uint32)]
        if self.native_guarded:
            if self.lib.gs_mmio_guarded_abi()!=1:raise ValueError('guarded MMIO ABI mismatch')
            self.lib.gs_mmio_slot_epoch.argtypes=[C.c_void_p,C.c_uint,C.c_uint64,C.POINTER(C.c_uint32)]
            self.lib.gs_mmio_slot_transfer.argtypes=[C.c_void_p,C.c_uint,C.c_uint64,C.c_uint32,C.c_uint32,
                                                   C.c_uint,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),C.c_uint]
        self.lib.gs_mmio_error.restype = C.c_char_p
        self.lib.gs_mmio_open.argtypes = [C.c_char_p, C.c_char_p, C.POINTER(C.c_void_p)]
        self.lib.gs_mmio_read.argtypes = [C.c_void_p, C.c_uint64, C.POINTER(C.c_uint32)]
        self.lib.gs_mmio_write.argtypes = [C.c_void_p, C.c_uint64, C.c_uint64]
        self.lib.gs_mmio_close.argtypes = [C.c_void_p]
        self.lib.gs_mmio_close.restype = None
        self._check(self.lib.gs_mmio_open(b'--file' if file_backend else b'--uio',
                                        os.fsencode(device), C.byref(self.handle)))

    def _check(self, result):
        if result:
            self.failed = True
            raise RuntimeError(self.lib.gs_mmio_error().decode('utf8', 'replace'))

    def _guard(self):
        if self.owner != (os.getpid(), threading.get_ident()):
            raise RuntimeError('native MMIO owner mismatch')
        if self.failed or not self.handle.value:
            raise RuntimeError('native MMIO closed or failed')

    @staticmethod
    def _offset(offset):
        if type(offset) is not int or not 0 <= offset <= 4092 or offset % 4:
            raise ValueError('unaligned or out of range')

    def read32(self, offset):
        self._guard(); self._offset(offset)
        result = C.c_uint32()
        self._check(self.lib.gs_mmio_read(self.handle, offset, C.byref(result)))
        return result.value

    def read32_many(self, offsets):
        self._guard()
        if not 1 <= len(offsets) <= 8:
            raise ValueError('read count range')
        for offset in offsets: self._offset(offset)
        return tuple(self.read32(offset) for offset in offsets)

    def write32(self, offset, value):
        self._guard(); self._offset(offset)
        if type(value) is not int or not 0 <= value <= 0xffffffff:
            raise ValueError('write value exceeds word')
        self._check(self.lib.gs_mmio_write(self.handle, offset, value))

    def slot_epoch(self,slot,token):
        self._guard();self._slot(slot,token)
        result=(C.c_uint32*2)()
        self._check(self.lib.gs_mmio_slot_epoch(self.handle,slot,token,result))
        return tuple(result)

    def _slot(self,slot,token):
        if not self.native_guarded:raise ValueError('native guard extension absent')
        if type(slot) is not int or not 0<=slot<4:raise ValueError('slot')
        if type(token) is not int or not 0<token<2**64:raise ValueError('lease token')

    def guarded_transfer(self,slot,token,epoch,offsets,values=None):
        self._guard();self._slot(slot,token)
        if type(epoch) is not tuple or len(epoch)!=2 or any(type(x) is not int or not 0<=x<2**32 for x in epoch):
            raise ValueError('expected physical/slot epoch')
        if type(offsets) not in (tuple,list) or not 1<=len(offsets)<=32:raise ValueError('transfer size')
        for offset in offsets:
            self._offset(offset)
            if offset>=0x400 or (slot==3 and offset>=0x300):raise ValueError('reserved slot offset')
        if values is not None and (type(values) not in (tuple,list) or len(values)!=len(offsets) or
                any(type(x) is not int or not 0<=x<2**32 for x in values)):raise ValueError('write words')
        addresses=(C.c_uint32*len(offsets))(*offsets)
        result=(C.c_uint32*len(offsets))(*(values if values is not None else [0]*len(offsets)))
        self._check(self.lib.gs_mmio_slot_transfer(self.handle,slot,token,*epoch,int(values is not None),addresses,result,len(offsets)))
        return tuple(result)

    def close(self):
        if self.owner != (os.getpid(), threading.get_ident()):
            raise RuntimeError('native MMIO close owner mismatch')
        if self.handle.value:
            self.lib.gs_mmio_close(self.handle)
            self.handle = C.c_void_p()

    def event_batch(self, slot, token, epoch, records, *, budget_ns):
        """Candidate ABI only; an old bitstream is rejected before any write."""
        self._guard();self._slot(slot,token)
        if not self.native_event_batch:raise ValueError('native event batch extension absent')
        if type(epoch) is not tuple or len(epoch)!=2 or any(type(x) is not int or not 0<=x<2**32 for x in epoch):
            raise ValueError('expected physical/slot epoch')
        if type(budget_ns) is not int or not 0<budget_ns<=50_000_000:
            raise ValueError('explicit 1..50000000ns batch budget required')
        if type(records) not in (tuple,list) or not 1<=len(records)<=16:
            raise ValueError('batch contains 1..16 events')
        if any(type(row) not in (tuple,list) or len(row)!=32 or
               any(type(v) is not int or not 0<=v<2**32 for v in row) for row in records):
            raise ValueError('each event must contain 32 uint32 words')
        values=(C.c_uint32*(32*len(records)))(*(v for row in records for v in row))
        result=(C.c_uint32*3)()
        rc=self.lib.gs_mmio_event_batch(self.handle,slot,token,*epoch,values,len(records),budget_ns,result)
        receipt=dict(accepted_prefix=result[0],bank_status=result[1],completion_unknown=bool(result[2]))
        if rc:
            self.failed=True
            raise EventBatchError(self.lib.gs_mmio_error().decode('utf8','replace'),receipt)
        return receipt
