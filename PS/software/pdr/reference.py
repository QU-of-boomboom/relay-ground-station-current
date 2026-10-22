"""PDR outcome-window reference. Offline accounting only; no hardware access."""
from dataclasses import dataclass


@dataclass(frozen=True)
class PacketId:
    node: int
    session: int
    sequence: int

    def __post_init__(self):
        for name, limit in (("node", 2**32-1), ("session", 2**64-1), ("sequence", 2**32-1)):
            value = getattr(self, name)
            low = 0 if name == "sequence" else 1
            if type(value) is not int or not low <= value <= limit:
                raise ValueError("invalid " + name)


def settle_batch(sent, received, *, closed=False):
    """Join a CLOSED, single-session transmit ledger to validated receive records.

    `closed` is an external experiment decision, never inferred from silence.
    Duplicate reception counts once. Unsent/foreign keys cannot add successes.
    This does not classify timestamps, queue age, send failures or wire payloads.
    """
    if closed is not True:
        raise ValueError("batch must be explicitly closed before settling losses")
    sent, received = list(sent), list(received)
    if any(not isinstance(k, PacketId) for k in sent + received):
        raise ValueError("PacketId records required")
    if len(set(sent)) != len(sent):
        raise ValueError("transmit key reused; retransmission accounting undefined")
    if len({(k.node, k.session) for k in sent}) > 1:
        raise ValueError("one node/session per batch")
    seen = set(received)
    return [k in seen for k in sent]


class OutcomeWindow:
    """Fixed ring, O(1) update; software arithmetic version of proposed RTL."""
    def __init__(self, window=64):
        if type(window) is not int or not 1 <= window <= 256:
            raise ValueError("window must be an integer in 1..256")
        self.window = window
        self.reset()

    def reset(self):
        self.bits = [0] * self.window
        self.pointer = self.count = self.delivered = 0

    def step(self, *, reset=False, valid=False, received=False):
        if any(type(x) is not bool for x in (reset, valid, received)):
            raise ValueError("boolean cycle inputs required")
        if reset:
            self.reset()
        elif valid:
            old = self.bits[self.pointer] if self.count == self.window else 0
            self.delivered += int(received) - old
            self.bits[self.pointer] = int(received)
            self.count = min(self.count + 1, self.window)
            self.pointer = 0 if self.pointer + 1 == self.window else self.pointer + 1
        return self.snapshot()

    def snapshot(self):
        return dict(count=self.count, delivered=self.delivered,
                    lost=self.count-self.delivered, valid=self.count != 0,
                    full=self.count == self.window,
                    permille=(1000*self.delivered//self.count if self.count else None))
