"""Pure PDR quality contract; no device, clock reader, alarm FSM or NPU access."""
from dataclasses import dataclass


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('integer outside contract range')


@dataclass(frozen=True)
class Policy:
    window: int
    min_count: int
    low_permille: int
    high_permille: int
    max_age_ms: int

    def __post_init__(self):
        integer(self.window, 1, 256)
        integer(self.min_count, 1, self.window)
        integer(self.low_permille, 0, 999)
        integer(self.high_permille, self.low_permille + 1, 1000)
        integer(self.max_age_ms, 1, 2**63-1)


def classify(policy, *, count, delivered, now_ms, observation_ms, update_ok):
    """observation_ms is trusted source evidence time, NEVER snapshot/read time.

    Both times must share a monotonic clock domain. None means unavailable.
    Result is a condition, not a flight action or sustained alarm decision.
    """
    if not isinstance(policy, Policy):
        raise ValueError('Policy required')
    integer(count, 0, policy.window)
    integer(delivered, 0, count)
    integer(now_ms, 0, 2**63-1)
    if type(update_ok) is not bool:
        raise ValueError('boolean update status required')
    if observation_ms is not None:
        integer(observation_ms, 0, now_ms)
    age = None if observation_ms is None else now_ms - observation_ms
    if not update_ok:
        condition = 'UPDATE_FAILED'
    elif count == 0:
        condition = 'NO_DATA'
    elif observation_ms is None:
        condition = 'TIME_UNKNOWN'
    elif age >= policy.max_age_ms:
        condition = 'STALE'
    elif count < policy.min_count:
        condition = 'WARMUP'
    elif 1000 * delivered <= policy.low_permille * count:
        condition = 'BAD'
    elif 1000 * delivered >= policy.high_permille * count:
        condition = 'GOOD'
    else:
        condition = 'BAND'
    usable = condition in ('BAD', 'GOOD', 'BAND')
    return dict(condition=condition, usable=usable, age_ms=age,
                full=count == policy.window,
                # Invalid evidence must not look like a current numeric PDR.
                permille=1000 * delivered // count if usable else None)
