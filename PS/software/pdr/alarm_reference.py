"""PDR alarm software model; no actuator, device or NPU access."""
from quality_reference import integer


class Alarm:
    def __init__(self, *, bad_hold_ms, good_hold_ms, max_step_gap_ms):
        for value in (bad_hold_ms, good_hold_ms, max_step_gap_ms):
            integer(value, 1, 2**63-1)
        self.bad_hold = bad_hold_ms
        self.good_hold = good_hold_ms
        self.max_gap = max_step_gap_ms
        self.identity = None
        self.last_time = None
        self._clear()

    def _clear(self):
        self.latched = False
        self.bad_since = self.good_since = None

    def step(self, *, identity, now_ms, condition):
        # Caller must classify freshness on EVERY tick, including while no packets arrive.
        if type(identity) is not tuple or len(identity) != 3:
            raise ValueError('identity=(node, session, epoch) required')
        for value, limit in zip(identity, (2**32-1, 2**64-1, 2**64-1)):
            integer(value, 1, limit)
        integer(now_ms, 0, 2**63-1)
        if condition not in ('BAD', 'GOOD', 'BAND', 'UPDATE_FAILED', 'NO_DATA',
                             'TIME_UNKNOWN', 'STALE', 'WARMUP'):
            raise ValueError('unknown quality condition')
        if self.last_time is not None and now_ms < self.last_time:
            raise ValueError('monotonic time moved backwards')
        discontinuity = (identity != self.identity or
                         (self.last_time is not None and now_ms-self.last_time > self.max_gap))
        if discontinuity:
            self._clear()
        self.identity, self.last_time = identity, now_ms
        if condition not in ('BAD', 'GOOD', 'BAND'):
            self._clear()
            return dict(valid=False, alarm=None, state='UNAVAILABLE', reason=condition,
                        continuity_reset=discontinuity)
        if condition == 'BAD':
            self.good_since = None
            if not self.latched:
                if self.bad_since is None:
                    self.bad_since = now_ms
                if now_ms-self.bad_since >= self.bad_hold:
                    self.latched = True
                    self.bad_since = None
        elif condition == 'GOOD':
            self.bad_since = None
            if self.latched:
                if self.good_since is None:
                    self.good_since = now_ms
                if now_ms-self.good_since >= self.good_hold:
                    self.latched = False
                    self.good_since = None
        else:
            # The hysteresis band preserves the alarm, but breaks both dwell timers.
            self.bad_since = self.good_since = None
        state = ('RECOVERING' if self.latched and self.good_since is not None else
                 'ALARM' if self.latched else
                 'PENDING_BAD' if self.bad_since is not None else 'CLEAR')
        return dict(valid=True, alarm=self.latched, state=state, reason=condition,
                    continuity_reset=discontinuity)
