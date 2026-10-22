"""Executable PDR transaction contract. No register, CDC or hardware access."""
from dataclasses import dataclass
from enum import IntEnum
from reference import OutcomeWindow


class Code(IntEnum):
    OK = 0
    DUPLICATE = 1
    INACTIVE = 2
    IDENTITY = 3
    OLD = 4
    GAP = 5
    CONFLICT = 6
    EXHAUSTED = 7
    INVALID = 8
    OLD_EPOCH = 9


@dataclass(frozen=True)
class Request:
    opcode: int
    tid: int
    epoch: int
    node: int
    session: int
    index: int = 0
    received: int = 0

    def pack(self):
        values = ((self.opcode, 8), (self.tid, 16), (self.epoch, 64),
                  (self.node, 32), (self.session, 64), (self.index, 32), (self.received, 1))
        if any(type(v) is not int or not 0 <= v < 1 << bits for v, bits in values):
            raise ValueError("request field outside wire width")
        return (self.opcode | (self.received << 8) | (self.tid << 16) |
                (self.epoch << 32) | (self.node << 96) |
                (self.session << 128) | (self.index << 192))


@dataclass(frozen=True)
class Response:
    tid: int
    code: Code
    active: bool
    epoch: int
    node: int
    session: int
    next_index: int
    count: int
    delivered: int
    full: bool

    def pack(self):
        flags = int(self.active) | (int(self.count != 0) << 1) | (int(self.full) << 2)
        counters = self.count | (self.delivered << 9)
        return (self.tid | (int(self.code) << 16) | (flags << 24) |
                (self.epoch << 32) | (self.next_index << 96) |
                (counters << 128) | (self.node << 160) | (self.session << 192))


class Executor:
    """BEGIN=1, OUTCOME=2, SNAPSHOT=3. All failures preserve business state."""
    def __init__(self, window=64):
        self.window = OutcomeWindow(window)
        self.active = False
        self.epoch = self.node = self.session = self.next_index = 0
        self.last_result = None

    def response(self, tid, code):
        s = self.window.snapshot()
        return Response(tid, code, self.active, self.epoch, self.node, self.session,
                        self.next_index, s["count"], s["delivered"], s["full"])

    def execute(self, word):
        if type(word) is not int or not 0 <= word < 1 << 256:
            raise ValueError("256-bit command required")
        op = word & 255
        received = (word >> 8) & 1
        tid = (word >> 16) & 65535
        epoch = (word >> 32) & (2**64-1)
        node = (word >> 96) & (2**32-1)
        session = (word >> 128) & (2**64-1)
        index = (word >> 192) & (2**32-1)
        if ((word >> 9) & 127) or (word >> 224) or op not in (1, 2, 3) or not epoch or not node or not session:
            return self.response(tid, Code.INVALID)
        if op != 2 and (index or received):
            return self.response(tid, Code.INVALID)
        identity = (epoch, node, session)
        current = (self.epoch, self.node, self.session)
        if op == 1:
            if self.active and epoch < self.epoch:
                return self.response(tid, Code.OLD_EPOCH)
            if self.active and epoch == self.epoch:
                return self.response(tid, Code.DUPLICATE if identity == current else Code.CONFLICT)
            self.epoch, self.node, self.session = identity
            self.active = True
            self.next_index = 0
            self.last_result = None
            self.window.reset()
            return self.response(tid, Code.OK)
        if not self.active:
            return self.response(tid, Code.INACTIVE)
        if identity != current:
            return self.response(tid, Code.IDENTITY)
        if op == 3:
            return self.response(tid, Code.OK)
        if self.next_index and index == self.next_index-1:
            return self.response(tid, Code.DUPLICATE if received == self.last_result else Code.CONFLICT)
        if index < self.next_index:
            return self.response(tid, Code.OLD)
        if self.next_index == 2**32-1:
            return self.response(tid, Code.EXHAUSTED)
        if index > self.next_index:
            return self.response(tid, Code.GAP)
        self.window.step(valid=True, received=bool(received))
        self.next_index += 1
        self.last_result = received
        return self.response(tid, Code.OK)


class Mailbox:
    """One slot: freeze command; hold immutable response until explicitly taken."""
    def __init__(self, executor):
        self.executor = executor
        self.pending = None
        self.result = None

    @property
    def ready(self):
        return self.pending is None and self.result is None

    def submit(self, request):
        if not self.ready:
            return False
        self.pending = request.pack()
        return True

    def service(self):
        if self.pending is not None:
            self.result = self.executor.execute(self.pending)
            self.pending = None
        return self.result

    def take(self):
        value = self.result
        self.result = None
        return value
