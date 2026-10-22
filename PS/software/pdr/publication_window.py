"""Pre-edge millisecond-window reference; no RTL, bus or device access."""
from dataclasses import dataclass
from typing import Optional
from alarm_reference import Alarm
from quality_reference import integer

REASONS=('INPUT_INVALID','NO_DATA','IDENTITY_MISMATCH','CONFIG_MISMATCH',
         'UPDATE_FAILED','TIME_UNKNOWN','STALE','WARMUP','BAD','BAND','GOOD')
CONDITIONS=('NO_DATA','UPDATE_FAILED','TIME_UNKNOWN','STALE','WARMUP','BAD','BAND','GOOD')


@dataclass(frozen=True)
class Sample:
    raw: int
    reason: str
    condition: str
    usable: bool
    evaluated_ms: int
    source_ms: Optional[int]
    context: int
    generation: int


def decode(payload, *, now_ms, active, generation):
    """Validate the public payload contract without recomputing link quality."""
    integer(payload,0,2**442-1)
    reason_code=payload>>438
    condition=CONDITIONS[(payload>>435)&7]
    if reason_code>=len(REASONS):raise ValueError('reserved reason')
    reason=REASONS[reason_code]
    mapped='UPDATE_FAILED' if reason in ('INPUT_INVALID','IDENTITY_MISMATCH','CONFIG_MISMATCH') else reason
    usable=bool((payload>>434)&1)
    if condition!=mapped or usable!=(condition in ('BAD','BAND','GOOD')):raise ValueError('quality fields disagree')
    if payload&((1<<64)-1)!=now_ms:raise ValueError('wrong evaluation window')
    if (payload>>418)&65535!=generation:raise ValueError('wrong publication generation')
    context=(payload>>64)&((1<<354)-1)
    origin=context>>130
    bound=(origin>>192,(origin>>128)&((1<<64)-1),(origin>>64)&((1<<64)-1),origin&((1<<64)-1))
    source=(context>>2)&((1<<64)-1) if context&2 else None
    if usable and (bound!=active or source is None or source>now_ms or not context&1):
        raise ValueError('usable result has invalid provenance')
    return Sample(payload,reason,condition,usable,now_ms,source,context,generation)


class PublicationWindow:
    """One call per FPGA edge using OLD Q, including rollover-edge publication.

    Cache changes revoke this window's candidate, but do not erase dwell time
    unless the window closes without a replacement. Configuration/fault clears
    immediately and inhibits the remainder of that millisecond.
    """
    def __init__(self,*,bad_hold_ms=2,good_hold_ms=2,max_step_gap_ms=1):
        self.policy=dict(bad_hold_ms=bad_hold_ms,good_hold_ms=good_hold_ms,max_step_gap_ms=max_step_gap_ms)
        self.alarm=Alarm(**self.policy)
        self.pending=None;self.active=None;self.last_time=None;self.last_closed=None
        self.blocked_ms=None;self.block_reason=None;self.sequence=0;self.available=False

    def _clear(self,now,reason):
        self.pending=None;self.alarm=Alarm(**self.policy);self.available=False
        self.blocked_ms=now;self.block_reason=reason

    def step(self,*,now_ms,active,configured=True,reset=False,clear=False,clock_fault=False,
             schedule_fault=False,change=False,rollover=False,generation=0,
             publication=False,current_valid=False,payload=0):
        integer(now_ms,0,2**63-1);integer(generation,0,255)
        if reset:
            self.__init__(**self.policy)
            return dict(captured=False,closed=None,available=False)
        if self.last_time is not None and now_ms<self.last_time:raise ValueError('time reversal without reset')
        self.last_time=now_ms
        if configured:
            if type(active) is not tuple or len(active)!=4:raise ValueError('active identity and revision required')
            for value,width in zip(active,(32,64,64,64)):integer(value,1,2**width-1)
        else:active=None
        if active!=self.active:
            self.active=active;self._clear(now_ms,'CONFIG_CLEAR')
        if not configured:self._clear(now_ms,'NOT_CONFIGURED')
        elif clear:self._clear(now_ms,'CONFIG_CLEAR')
        elif clock_fault:self._clear(now_ms,'CLOCK_FAULT')
        elif schedule_fault:self._clear(now_ms,'SCHEDULE_FAULT')
        if self.pending is not None and (self.pending.generation!=generation or self.pending.evaluated_ms!=now_ms):
            self.pending=None;self.available=False
        if change or not current_valid:
            self.pending=None
        if change:self.available=False
        captured=False
        if publication and current_valid and not change and self.blocked_ms!=now_ms:
            try:self.pending=decode(payload,now_ms=now_ms,active=active,generation=generation)
            except ValueError:self._clear(now_ms,'INTERFACE_INVALID')
            else:captured=True
        closed=None
        if rollover:
            if self.last_closed==now_ms:raise ValueError('duplicate window close')
            self.last_closed=now_ms
            sample=self.pending if self.blocked_ms!=now_ms else None
            condition=sample.condition if sample is not None else 'UPDATE_FAILED'
            reason=sample.reason if sample is not None else (self.block_reason if self.blocked_ms==now_ms else 'NO_PUBLICATION')
            if active is None:
                result=dict(valid=False,alarm=None,state='UNAVAILABLE',reason=condition,continuity_reset=True)
            else:result=self.alarm.step(identity=active[:3],now_ms=now_ms,condition=condition)
            self.sequence=(self.sequence+1)&((1<<64)-1)
            self.available=result['valid']
            closed=dict(sequence=self.sequence,active=active,evaluated_ms=now_ms,
                        condition=condition,reason=reason,sample=sample,alarm=result.copy())
            self.pending=None
        return dict(captured=captured,closed=closed,available=self.available)
