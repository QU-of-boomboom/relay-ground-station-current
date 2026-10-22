"""Bounded journal grouping; hardware intent/result remain durability barriers."""
import hashlib
import os
import time
from ledger_station import Journal, canonical


class GroupedJournal(Journal):
    BARRIERS = frozenset(('header', 'intent', 'result', 'counter_check', 'abort', 'stop'))

    def __init__(self, path):
        super().__init__(path)
        self.pending = bytearray()
        self.failed = False
        self.last_flush = time.monotonic_ns()
        self.limit = 65536

    def flush(self):
        if self.failed:
            raise OSError('journal durability previously failed; no retry')
        if not self.pending:
            return
        try:
            if self.file.write(self.pending) != len(self.pending):
                raise OSError('short journal write')
            self.file.flush()
            os.fsync(self.file.fileno())
        except BaseException:
            self.failed = True
            raise
        self.pending.clear()
        self.last_flush = time.monotonic_ns()

    def append(self, kind, data):
        if self.failed or self.file.closed:
            raise OSError('journal unavailable')
        row = dict(sequence=self.sequence, previous=self.previous, kind=kind, data=data)
        digest = hashlib.sha256(canonical(row).encode('utf8')).hexdigest()
        row['sha256'] = digest
        encoded = (canonical(row)+'\n').encode('utf8')
        if len(encoded) > self.limit:
            self.failed = True
            raise ValueError('journal record exceeds bounded buffer')
        if len(self.pending)+len(encoded) > self.limit:
            self.flush()
        self.pending.extend(encoded)
        self.sequence += 1
        self.previous = digest
        if kind in self.BARRIERS:
            self.flush()

    def flush_due(self):
        if time.monotonic_ns()-self.last_flush >= 250_000_000:
            self.flush()

    def close(self):
        if self.file.closed:
            return
        try:
            if not self.failed:
                self.flush()
        finally:
            self.file.close()
