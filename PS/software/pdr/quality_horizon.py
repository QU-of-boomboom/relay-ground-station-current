"""Immutable PS-time envelope for a bounded PL quality transaction.

The eventual consumer must reject at deadline, including post-read guard time.
Nothing in this module equates a PL counter with the host clock.
"""
from dataclasses import dataclass

from ledger_station import MonitorSettings
from online_station import ContinuousStation
from quality_reference import integer
from timing_metrics import TimingMetrics


@dataclass(frozen=True)
class QualityHorizon:
    settings: MonitorSettings
    slot: int
    tag: int
    required: int
    clock_domain: str
    started_ns: int
    deadline_ns: int
    pdr_available: bool
    expected_pdr: int
    rtt: tuple
    aoi: tuple
    source_fingerprint: tuple

    def __post_init__(self):
        if not isinstance(self.settings,MonitorSettings):raise ValueError('bound monitor settings required')
        integer(self.slot,0,3);integer(self.tag,1,2**32-1);integer(self.required,1,7)
        integer(self.started_ns,0,2**63-2);integer(self.deadline_ns,self.started_ns+1,2**63-1)
        integer(self.expected_pdr,0,3)
        if (not self.required & 1 or type(self.pdr_available) is not bool or
            type(self.clock_domain) is not str or not self.clock_domain or
            type(self.source_fingerprint) is not tuple or not self.source_fingerprint):
            raise ValueError('explicit immutable quality binding required')
        for interval in (self.rtt,self.aoi):
            if type(interval) is not tuple or len(interval)!=5 or type(interval[4]) is not bool:
                raise ValueError('immutable qualified interval required')
            for value in interval[:4]:integer(value,0,2**64-1)

    def words(self):
        flags=(self.slot | self.required<<2 | int(self.rtt[4])<<5 |
               int(self.aoi[4])<<6 | int(self.pdr_available)<<7)
        s=self.settings
        identity=(s.node<<192)|(s.session<<128)|(s.epoch<<64)|s.revision
        values=[self.tag,flags]+[(identity>>(32*i))&0xffffffff for i in range(7)]
        for value in self.rtt[:4]+self.aoi[:4]:
            values.extend((value&0xffffffff,value>>32))
        assert len(values)==25
        return tuple(values)

    def check_completion(self, now_ns, station, timing):
        integer(now_ns,self.started_ns,self.deadline_ns-1)
        if station.settings!=self.settings or fingerprint(station,timing)!=self.source_fingerprint:
            raise ValueError('bound quality sources changed during PL transaction')
        if station.failed or station.closed or station.engine.stopped or timing.stopped:
            raise ValueError('quality source stopped during PL transaction')


def fingerprint(station,timing):
    e=station.engine
    return (station.settings,e.node,e.session,e.next_index,station.confirmed,tuple(station.ring),
        e.tx_watermark,e.rx_watermark,e.last_closed,e.stopped,e.timeout,e.max_age,e.deadline_origin,
        timing.node,timing.session,timing.domain,tuple(timing.samples),timing.highest_state,
        timing.generation,timing.state_received,timing.stopped,timing.max_age,
        timing.rtt_good,timing.rtt_bad,timing.aoi_good,timing.aoi_bad)


def prepare_horizon(station,timing,*,slot,tag,required,started_ns,horizon_ns,clock_domain):
    if not isinstance(station,ContinuousStation) or not isinstance(timing,TimingMetrics):
        raise ValueError('production station and timing sources required')
    integer(slot,0,3);integer(tag,1,2**32-1);integer(required,1,7)
    integer(started_ns,0,2**63-2);integer(horizon_ns,1,2**63-1-started_ns)
    if not required & 1:raise ValueError('PDR is mandatory')
    if (type(clock_domain) is not str or not clock_domain or timing.domain!=clock_domain or
        (station.settings.node,station.settings.session)!=(timing.node,timing.session)):
        raise ValueError('source identity/time domain mismatch')
    deadline=started_ns+horizon_ns
    pdr=station.status(started_ns)
    metrics=timing.status(started_ns)
    engine=station.engine;observed=engine.last_closed
    pdr_live=(pdr['quality_usable'] and observed is not None and
        min(engine.tx_watermark+engine.timeout,engine.rx_watermark+engine.timeout,
            observed+engine.max_age,(observed//1_000_000+station.settings.policy.max_age_ms)*1_000_000)>=deadline)
    # Bound the rolling maximum over [started_ns, deadline). Expiring samples
    # still contribute to the upper bound; surviving samples bound it below.
    # No new observations can enter this immutable transaction (fingerprint).
    # Thus a high sample is never silently removed, and mixed classifications
    # remain uncertain in PL instead of being decided by the host.
    samples=tuple((v,t) for v,t in timing.samples if started_ns-t<timing.max_age)
    survivors=tuple(v for v,t in samples if t+timing.max_age>=deadline)
    rtt_live=bool(metrics['active'] and survivors)
    worst=max((v for v,_ in samples),default=0)
    rtt=(max(survivors,default=0),worst,timing.rtt_good,timing.rtt_bad,rtt_live)
    generation=timing.generation
    aoi_live=bool(metrics['active'] and generation is not None and
        generation.clock_domain==clock_domain and generation.upper_ns<=started_ns and
        timing.state_received is not None and timing.state_received+timing.max_age>=deadline)
    aoi=(started_ns-generation.upper_ns if aoi_live else 0,
         deadline-generation.lower_ns if aoi_live else 0,timing.aoi_good,timing.aoi_bad,aoi_live)
    expected={'BAD':1,'BAND':2,'GOOD':3}.get(pdr['pdr_quality']['condition'],0) if pdr_live else 0
    return QualityHorizon(station.settings,slot,tag,required,clock_domain,started_ns,deadline,
        bool(pdr_live),expected,rtt,aoi,fingerprint(station,timing))
