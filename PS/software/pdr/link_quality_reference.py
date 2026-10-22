"""Stateless interval and required-metric fusion oracle; no RTL pipeline state."""
from quality_reference import integer


def interval(lower,upper,good,bad,available):
    for value in (lower,upper,good,bad):integer(value,0,2**64-1)
    if type(available) is not bool:raise ValueError('explicit source/time qualification')
    if lower>upper or good>=bad:return 0,1
    if not available:return 0,2
    if upper<=good:return 3,0
    if lower>=bad:return 1,0
    if lower>good and upper<bad:return 2,0
    return 0,3


def compose(pdr,rtt,aoi,required):
    for condition in (pdr,rtt,aoi):integer(condition,0,3)
    integer(required,0,7)
    missing=sum(1<<index for index,condition in enumerate((pdr,rtt,aoi))
                if required & (1<<index) and condition==0)
    if not required & 1:return dict(condition=0,missing=missing,invalid=True)
    if missing:return dict(condition=0,missing=missing,invalid=False)
    conditions=[value for bit,value in enumerate((pdr,rtt,aoi)) if required & (1<<bit)]
    return dict(condition=1 if 1 in conditions else 2 if 2 in conditions else 3,
                missing=0,invalid=False)


def evaluate(tag,pdr,required,rtt,aoi):
    integer(tag,0,2**32-1)
    rtt_condition,rtt_reason=interval(*rtt)
    aoi_condition,aoi_reason=interval(*aoi)
    return dict(tag=tag,**compose(pdr,rtt_condition,aoi_condition,required),
                rtt_condition=rtt_condition,rtt_reason=rtt_reason,
                aoi_condition=aoi_condition,aoi_reason=aoi_reason)
