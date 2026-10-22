"""Bridge authenticated host-grant batches into one real online PL station.

The selected metric must explicitly be host_grant. Autonomous sender-clock
telemetry must not use this adapter or borrow its causal generation bounds.
"""
import threading

from online_station import ContinuousStation
from quality_reference import integer
from remote_round_protocol import RemoteFault
from remote_round_udp import RemoteHostUdp
from timing_metrics import TimingMetrics, GenerationBounds
from clock_mapping import ClockMapping, Exchange
from remote_timed_sample import decode as decode_timed


class RemoteStationLane:
    def __init__(self, station, timing, host, *, clock_domain, quantum=4, clock_mapper=None):
        if not isinstance(station,ContinuousStation) or not isinstance(timing,TimingMetrics) or not isinstance(host,RemoteHostUdp):
            raise ValueError('production station, timing and remote host required')
        integer(quantum,1,64)
        e=station.engine
        if (e.deadline_origin!='host_grant' or e.budget!=host.budget or
            (e.node,e.session)!=(host.node,host.session) or
            (timing.node,timing.session,timing.domain)!=(e.node,e.session,clock_domain)):
            raise ValueError('remote metric, identity, budget and clock domain must match')
        if e.highest!=-1 or e.pending or timing.highest_probe!=-1 or host.active is not None:
            raise ValueError('fresh bound inputs required; no auto-resume')
        if station.closed or station.failed or timing.stopped or host.stopped:
            raise ValueError('active sources required')
        self.station,self.timing,self.host=station,timing,host
        self.domain,self.quantum=clock_domain,quantum
        if clock_mapper is not None and (not isinstance(clock_mapper,ClockMapping) or
                (clock_mapper.node,clock_mapper.session,clock_mapper.host_domain)!=(e.node,e.session,clock_domain)
                or clock_mapper.last is not None or clock_mapper.stopped):
            raise ValueError('fresh mapper with matching station identity/domain required')
        self.clock_mapper=clock_mapper
        self.mapper_binding=None if clock_mapper is None else (
            clock_mapper.node,clock_mapper.session,clock_mapper.remote_domain,clock_mapper.host_domain,
            clock_mapper.rate,clock_mapper.max_age,clock_mapper.max_extrapolation)
        self.mapping_status='NOT_CONFIGURED' if clock_mapper is None else 'NO_DATA'
        self.binding=(station.settings,e.node,e.session,e.budget,e.deadline_origin,
                      timing.node,timing.session,timing.domain,host.node,host.session,host.nonce,host.budget)
        self.imported_round=0;self.owner=threading.get_ident()
        self.stopped=self.busy=False

    def _enter(self):
        if threading.get_ident()!=self.owner or self.busy or self.stopped:
            raise RemoteFault('remote lane requires active nonreentrant owner')
        e,t,h=self.station.engine,self.timing,self.host
        current=(self.station.settings,e.node,e.session,e.budget,e.deadline_origin,
                 t.node,t.session,t.domain,h.node,h.session,h.nonce,h.budget)
        if current!=self.binding:
            self._fail()
            raise RemoteFault('remote lane binding changed')
        m=self.clock_mapper
        current_mapper=None if m is None else (m.node,m.session,m.remote_domain,m.host_domain,
                                               m.rate,m.max_age,m.max_extrapolation)
        if current_mapper!=self.mapper_binding:
            self._fail()
            raise RemoteFault('remote clock mapping premise changed')
        self.busy=True

    def stop(self,reason='REMOTE_LANE_STOP'):
        if threading.get_ident()!=self.owner or self.busy:
            raise RemoteFault('stop requires idle owner thread')
        self.stopped=True
        self.station.engine.stop(reason);self.timing.stop(reason)
        try:self.host.close(reason)
        finally:self.station.close(reason)

    def _fail(self):
        # Preserve the original failure while revoking both quality sources first.
        self.stopped=True
        self.station.engine.stop('REMOTE_LANE_FAILED');self.timing.stop('REMOTE_LANE_FAILED')
        try:self.host.close('REMOTE_LANE_FAILED')
        except BaseException:pass
        try:self.station.close('REMOTE_LANE_FAILED')
        except BaseException:pass

    def begin(self,count):
        self._enter()
        try:
            integer(count,1,min(64,self.station.engine.capacity))
            if self.station.engine.pending:
                raise RemoteFault('settlement backlog must drain before next grant')
            if self.host.active and self.imported_round!=self.host.active.context.round:
                raise RemoteFault('previous grant not imported')
            context=self.host.begin(count)
            self.timing.probe_sent(context.base,True,self.host.active.started)
            return context
        except BaseException:self._fail();raise
        finally:self.busy=False

    def poll(self,drain_limit=256):
        self._enter()
        try:
            closed=self.host.pump(drain_limit)
            now=self.host._now()
            if closed is not None and closed.context.round!=self.imported_round:
                c=closed.context
                if closed is not self.host.active.closed:
                    raise RemoteFault('unbound closed round')
                # Parse all explicit-profile records before adding any facts
                # to PL. An arbitrary opaque payload never opts into mapping.
                mapped_generation=self._map_generation(closed,now)
                # The origin is the explicitly declared grant timestamp. Full
                # send facts are required before any denominator enters PL.
                for index in range(c.count):
                    self.station.tx(c.base+index,bool(closed.send_mask & (1<<index)),closed.started_ns,now)
                for index,observed,payload,fresh in sorted(closed.received,key=lambda row:row[1]):
                    self.station.rx(c.node,c.session,c.base+index,observed,now)
                if closed.received:
                    first=min(closed.received,key=lambda row:row[1])
                    self.timing.reply(c.node,c.session,c.base,first[1],now)
                    latest=max(closed.received,key=lambda row:row[0])
                    generation=GenerationBounds(closed.started_ns,latest[1],self.domain) if latest[3] else None
                    if mapped_generation is not None:
                        if generation is None:generation=mapped_generation
                        else:
                            generation=GenerationBounds(max(generation.lower_ns,mapped_generation.lower_ns),
                                min(generation.upper_ns,mapped_generation.upper_ns),self.domain)
                    self.timing.state(c.node,c.session,c.base+latest[0],generation,latest[1],now)
                self.imported_round=c.round
            committed=()
            if closed is not None:
                watermark=closed.closed_ns-1
                committed=self.station.advance(watermark,watermark,now,max_outcomes=self.quantum)
            # Actual PL calls above may consume host time; never stamp status
            # with the pre-call timestamp or extend an old source watermark.
            now=self.host._now()
            return dict(round=self.host.active.context.round,closed=closed is not None,
                committed=len(committed),station=self.station.status(now),timing=self.timing.status(now),
                deadline_origin='host_grant',clock_mapping=self.mapping_status,board_verified=False)
        except BaseException:self._fail();raise
        finally:self.busy=False

    def _map_generation(self,closed,now):
        if self.clock_mapper is None or not closed.received:return None
        records={index:decode_timed(payload) for index,observed,payload,fresh in closed.received}
        prior=None
        for index,observed,payload,fresh in sorted(closed.received):
            record=records[index]
            if record.clock_domain.hex()!=self.clock_mapper.remote_domain:
                raise RemoteFault('authenticated sensor clock domain mismatch')
            if fresh and record.generated_ns<record.grant_received_ns:
                raise RemoteFault('fresh sensor generation predates grant')
            if prior is not None and (record.grant_received_ns!=prior.grant_received_ns
                                     or record.sent_ns<prior.sent_ns):
                raise RemoteFault('inconsistent remote grant/send clock evidence')
            prior=record
        first=min(closed.received,key=lambda row:row[1])
        stamp=records[first[0]]
        c=closed.context
        self.clock_mapper.observe(Exchange(c.node,c.session,stamp.clock_domain.hex(),c.round,
            closed.started_ns,stamp.grant_received_ns,stamp.sent_ns,first[1]),now)
        latest=max(closed.received,key=lambda row:row[0])
        stamp=records[latest[0]]
        result=self.clock_mapper.generation(node=c.node,session=c.session,
            remote_domain=stamp.clock_domain.hex(),generated_ns=stamp.generated_ns,
            remote_sent_ns=stamp.sent_ns,received_ns=latest[1],now_ns=now)
        self.mapping_status=result.reason
        return result.generation
