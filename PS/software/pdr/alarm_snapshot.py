"""Decode a coherent PL snapshot. Bus address/locking protocol is deliberately not implied."""
from typing import Optional
from dataclasses import dataclass
from quality_reference import integer
from publication_window import REASONS,CONDITIONS

STATES=('UNAVAILABLE','CLEAR','PENDING_BAD','ALARM','RECOVERING')


@dataclass(frozen=True)
class AlarmSnapshot:
    sequence: int
    active: tuple
    evaluated_ms: int
    present: bool
    quality_reason: Optional[str]
    condition: Optional[str]
    source_ms: Optional[int]
    payload: int
    state: str
    valid: bool
    alarm: Optional[bool]


def decode_snapshot(raw):
    """Accept exactly one 800-bit integer or one coherent 100-byte LE record."""
    if isinstance(raw,bytes):
        if len(raw)!=100:raise ValueError('exactly 100 snapshot bytes required')
        raw=int.from_bytes(raw,'little')
    integer(raw,0,2**800-1)
    sequence=raw>>736;active_raw=(raw>>512)&((1<<224)-1);mask=(1<<64)-1
    active=(active_raw>>192,(active_raw>>128)&mask,(active_raw>>64)&mask,active_raw&mask)
    evaluated=(raw>>448)&mask;present=bool((raw>>447)&1);payload=(raw>>5)&((1<<442)-1)
    state=(raw>>2)&7;valid=bool((raw>>1)&1);alarm=bool(raw&1)
    if state>=len(STATES) or valid!=(state!=0) or alarm!=(state in (3,4)):raise ValueError('inconsistent alarm fields')
    if evaluated>=2**63:raise ValueError('invalid evaluation time')
    if not present and payload:raise ValueError('absent sample must have zero payload')
    reason=condition=source=None
    if present:
        reason_code=payload>>438
        if reason_code>=len(REASONS):raise ValueError('reserved quality reason')
        reason=REASONS[reason_code];condition=CONDITIONS[(payload>>435)&7]
        expected='UPDATE_FAILED' if reason in ('INPUT_INVALID','IDENTITY_MISMATCH','CONFIG_MISMATCH') else reason
        if condition!=expected:raise ValueError('inconsistent quality reason')
        usable=bool((payload>>434)&1)
        if usable!=(condition in ('BAD','BAND','GOOD')) or valid!=usable:raise ValueError('quality and alarm availability differ')
        if payload&mask!=evaluated:raise ValueError('mixed snapshot timestamps')
        context=(payload>>64)&((1<<354)-1)
        source=(context>>2)&mask if context&2 else None
        if valid:
            if context>>130!=active_raw or source is None or source>evaluated or not context&1:
                raise ValueError('mixed snapshot provenance')
    elif valid:raise ValueError('alarm valid without a quality sample')
    return AlarmSnapshot(sequence,active,evaluated,present,reason,condition,source,payload,STATES[state],valid,alarm if valid else None)
