"""Foreground production wiring: explicit UDP peers, leased PL, fair scheduling.

Reports hardware quality but does not dispatch relay commands: verified physical
path provenance and an actual executor are separate deployment requirements.
"""
from dataclasses import asdict
from pathlib import Path
import socket
import time
import uuid

from ledger_station import Journal
from link_service_client import LinkServiceClient,HardwareQualityAdapter
from multinode_online import MultiNodeOnline,SlotSettings
from physical_transport import PhysicalSlotTransport,PhysicalQualityTransport
from quality_horizon import fingerprint
from remote_deployment import Deployment
from remote_fleet import RemoteFleet
from remote_round_udp import RemoteHostUdp
from remote_station_lane import RemoteStationLane
from timing_metrics import TimingMetrics
from wire_run_identity import reserve,WireRunClaim
from clock_mapping import ClockMapping,RateEvidence
from router_snapshot import RouterSnapshotReader


def validate_keys(config, keys):
    """Validate private bytes without logging or touching devices."""
    if (not isinstance(keys, tuple) or len(keys) != len(config.nodes) or
            any(type(key) is not bytes or len(key) != 32 for key in keys)):
        raise ValueError('one 32-byte binary key per configured node required')
    if len(set(keys)) != len(keys):
        raise ValueError('distinct node keys required')
    return keys


def read_keys(config):
    # Bounded reads also reject unexpectedly large key files before a lease is claimed.
    keys = []
    for node in config.nodes:
        with node.key_file.open('rb') as stream:
            keys.append(stream.read(33))
    return validate_keys(config, tuple(keys))


def reserve_identities(config):
    return tuple(reserve(config.identity_root,role='host',node=node.monitor.node,
        session=node.monitor.session,nonce=node.nonce) for node in config.nodes)


class RemoteStationRuntime:
    def __init__(self,config,directory,claimed_bus,*,clock_ns=time.monotonic_ns,keys=None,claims=None,router_observer=None):
        if not isinstance(config,Deployment):raise ValueError('validated deployment required')
        if not callable(getattr(claimed_bus,'verify_lifetime',None)):raise ValueError('claimed physical bus required')
        if router_observer is not None and not isinstance(router_observer,RouterSnapshotReader):
            raise ValueError('explicit local router snapshot reader required')
        if router_observer is not None and router_observer.nodes!=tuple(n.monitor.node for n in config.nodes):
            raise ValueError('router observer nodes must match deployed nodes')
        self.router_observer=router_observer
        self.config,self.directory,self.bus,self.clock=config,Path(directory),claimed_bus,clock_ns
        self.manager=self.fleet=self.journal=None;self.sockets=[];self.hosts=[];self.metrics=[];self.adapters=[]
        self.closed=False;self.last_quality=None;self.next_quality=0;self.cleanup_errors=[];self.quality_sources={}
        # Validate all named keys before creating sockets or issuing any PL configuration.
        keys=read_keys(config) if keys is None else validate_keys(config,keys)
        if self.directory.exists():raise FileExistsError('new runtime directory required')
        claims=reserve_identities(config) if claims is None else claims
        if type(claims) is not tuple or len(claims)!=len(config.nodes) or any(not isinstance(claim,WireRunClaim) for claim in claims):
            raise ValueError('one persistent identity claim per node required')
        for claim,node in zip(claims,config.nodes):
            claim.consume('host',node.monitor.node,node.monitor.session,node.nonce)
        self.directory.mkdir(parents=True)
        for name in ('station','fleet','network'):(self.directory/name).mkdir()
        self.domain='ps_monotonic:'+uuid.uuid4().hex
        try:
            self.journal=Journal(self.directory/'runtime.jsonl')
            # Backend selection is provenance, never evidence of board validation.
            physical_backend=getattr(getattr(claimed_bus,'raw',None),'hardware_backend',False) is True
            self.journal.append('header',dict(schema=1,clock_domain=self.domain,slots=[n.slot for n in config.nodes],
                deadline_origin='host_grant',physical_backend=physical_backend,
                physical_backend_verified=False,board_verified=False,
                relay_dispatch=False,physical_path_verified=False))
            for node in config.nodes:
                sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.sockets.append(sock);sock.bind(node.bind)
            started=clock_ns()
            specs=tuple(SlotSettings(n.slot,n.monitor,config.budget_ns,
                source_timeout_ns=config.source_timeout_ns,statistics_age_ns=config.statistics_age_ns,
                deadline_origin='host_grant') for n in config.nodes)
            self.manager=MultiNodeOnline(self.directory/'station',specs,
                lambda slot:PhysicalSlotTransport(claimed_bus,slot),started_ns=started,quantum=config.quantum)
            service=LinkServiceClient(PhysicalQualityTransport(claimed_bus),clock_domain=self.domain,clock_ns=clock_ns)
            lanes={}
            for node,key,sock in zip(config.nodes,keys,self.sockets):
                timing=TimingMetrics(node=node.monitor.node,session=node.monitor.session,
                    clock_domain=self.domain,started_ns=started,**dict(config.timing));self.metrics.append(timing)
                host=RemoteHostUdp(sock,node.peer,self.directory/'network'/f'host_slot{node.slot}.jsonl',
                    node=node.monitor.node,session=node.monitor.session,nonce=node.nonce,key=key,
                    budget_ns=config.budget_ns,facts_timeout_ns=config.facts_timeout_ns,clock_ns=clock_ns)
                self.hosts.append(host)
                station=self.manager.stations[node.slot]
                mapping=None
                if node.clock_mapping is not None:
                    options=dict(node.clock_mapping)
                    remote_domain=options.pop('remote_domain_hex')
                    rate=RateEvidence(options.pop('rate_ppm'),options.pop('rate_evidence'))
                    mapping=ClockMapping(node=node.monitor.node,session=node.monitor.session,
                        remote_domain=remote_domain,host_domain=self.domain,rate=rate,started_ns=started,**options)
                    self.journal.append('clock_mapping_premise',dict(slot=node.slot,
                        remote_domain=remote_domain,rate_ppm=rate.ppm,rate_evidence=rate.reference,
                        **options,device_clock_verified_by_this_run=False))
                lanes[node.slot]=RemoteStationLane(station,timing,host,clock_domain=self.domain,
                    quantum=config.quantum,clock_mapper=mapping)
                self.adapters.append(HardwareQualityAdapter(service,station,timing,slot=node.slot,
                    required=config.quality_required,horizon_ns=config.quality_horizon_ns,direct_path=False))
            self.fleet=RemoteFleet(self.directory/'fleet',lanes,count=config.count,period_ns=config.period_ns,
                retry_interval_ns=config.retry_interval_ns,clock_ns=clock_ns,drain_limit=config.drain_limit)
        except BaseException:
            try:self.close('RUNTIME_START_FAILED')
            except BaseException as cleanup:self.cleanup_errors.append(type(cleanup).__name__)
            raise

    def poll(self):
        if self.closed:raise RuntimeError('runtime closed')
        try:
            result=self.fleet.poll();now=self.clock()
            if now>=self.next_quality and not result['stopped']:
                qualities={}
                for node,adapter in zip(self.config.nodes,self.adapters):
                    if node.slot in self.fleet.failures:
                        qualities[node.slot]=dict(condition='UNAVAILABLE',source_failed=True)
                    else:
                        event,completed=adapter.sample()
                        qualities[node.slot]=dict(event=asdict(event),read_completed_ns=completed,
                            event_not_expired=completed<event.expires_ns)
                        self.quality_sources[node.slot]=fingerprint(adapter.station,adapter.timing)
                self.last_quality=qualities
                self.next_quality=self.clock()+self.config.quality_period_ns
                self.journal.append('hardware_quality',dict(qualities=qualities,recorded_ns=self.clock(),board_verified=False))
            now=self.clock();qualities={}
            for node,adapter in zip(self.config.nodes,self.adapters):
                row=(self.last_quality or {}).get(node.slot)
                if row is None:continue
                if 'event' not in row:qualities[node.slot]=dict(row);continue
                not_expired=now<row['event']['expires_ns']
                current=(not_expired and not adapter.station.closed and not adapter.station.failed and
                    adapter.station.engine.stopped is None and adapter.timing.stopped is None and
                    fingerprint(adapter.station,adapter.timing)==self.quality_sources.get(node.slot))
                qualities[node.slot]=dict(row,event_not_expired=not_expired,event_current=current,reported_ns=now)
            status=dict(fleet=result,qualities=qualities,relay_dispatch=False,
                        physical_path_verified=False,board_verified=False)
            if self.router_observer is not None:
                # Informational only; do not feed this into adapters/fleet/relay.
                observation=self.router_observer.read(now)
                self.journal.append('router_observation',observation)
                status['router_observation']=observation
            return status
        except BaseException:
            try:self.close('RUNTIME_OPERATION_FAILED')
            except BaseException as cleanup:self.cleanup_errors.append(type(cleanup).__name__)
            raise

    def close(self,reason='NORMAL_STOP'):
        if self.closed:return
        self.closed=True
        # All source qualifications are revoked before filesystem/socket cleanup.
        for timing in self.metrics:timing.stop(reason)
        if self.manager:
            for station in self.manager.stations.values():station.engine.stop(reason)
        errors=[]
        for component in ([self.fleet] if self.fleet else [])+self.hosts+([self.manager] if self.manager else []):
            try:component.close(reason)
            except BaseException as error:errors.append(type(error).__name__)
        for sock in self.sockets:
            try:sock.close()
            except BaseException as error:errors.append(type(error).__name__)
        if self.journal:
            journal,self.journal=self.journal,None
            try:journal.append('stop',dict(reason=reason,cleanup_errors=errors))
            except BaseException as error:errors.append(type(error).__name__)
            try:journal.close()
            except BaseException as error:errors.append(type(error).__name__)
        self.cleanup_errors.extend(errors)
        if errors:raise RuntimeError('runtime cleanup incomplete: '+','.join(errors))
