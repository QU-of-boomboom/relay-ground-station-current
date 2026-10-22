"""Strict explicit deployment configuration; parsing does not touch hardware."""
from dataclasses import dataclass
import json
from pathlib import Path
import re

from ledger_plan import unique_object
from ledger_station import MonitorSettings
from quality_reference import Policy,integer
from remote_round_protocol import Context
from remote_round_udp import validate_peer
from clock_mapping import RateEvidence


def fields(value,names):
    if type(value) is not dict or set(value)!=set(names.split()):raise ValueError('configuration fields mismatch: '+names)
    return value


@dataclass(frozen=True)
class NodeDeployment:
    slot: int
    monitor: MonitorSettings
    nonce: bytes
    key_file: Path
    bind: tuple
    peer: tuple
    clock_mapping: tuple | None = None


@dataclass(frozen=True)
class Deployment:
    helper: Path
    identity_root: Path
    uio: str
    helper_timeout_seconds: float
    hardware_window: int
    nodes: tuple
    count: int
    period_ns: int
    budget_ns: int
    facts_timeout_ns: int
    retry_interval_ns: int
    source_timeout_ns: int
    statistics_age_ns: int
    quantum: int
    drain_limit: int
    poll_interval_ns: int
    timing: tuple
    quality_required: int
    quality_horizon_ns: int
    quality_period_ns: int


def parse(raw,base):
    fields(raw,'schema helper identity_root uio helper_timeout_seconds hardware_window nodes rounds timing quality')
    if type(raw['schema']) is not int or raw['schema']!=2:raise ValueError('deployment schema 2 required')
    if type(raw['uio']) is not str or not re.fullmatch('/dev/uio(0|[1-9][0-9]{0,3})',raw['uio']):raise ValueError('canonical Linux UIO device required')
    timeout=raw['helper_timeout_seconds']
    if type(timeout) not in (int,float) or not 0<timeout<=60:raise ValueError('helper timeout')
    integer(raw['hardware_window'],1,256)
    def local_path(value):
        if type(value) is not str or not value or '\0' in value:raise ValueError('explicit local path required')
        return (Path(base)/value).resolve()
    helper=local_path(raw['helper'])
    r=fields(raw['rounds'],'count period_ns budget_ns facts_timeout_ns retry_interval_ns source_timeout_ns statistics_age_ns quantum drain_limit poll_interval_ns')
    integer(r['count'],1,64);integer(r['quantum'],1,64);integer(r['drain_limit'],1,65536)
    for name in ('period_ns','budget_ns','facts_timeout_ns','retry_interval_ns','source_timeout_ns','statistics_age_ns','poll_interval_ns'):
        integer(r[name],1,2**63-1)
    if r['facts_timeout_ns']<=r['budget_ns'] or r['retry_interval_ns']>=r['facts_timeout_ns']:
        raise ValueError('facts timeout must exceed deadline and retry interval')
    t=fields(raw['timing'],'probe_timeout_ns max_sample_age_ns rtt_good_ns rtt_bad_ns aoi_good_ns aoi_bad_ns capacity window')
    integer(t['probe_timeout_ns'],1,2**63-1);integer(t['max_sample_age_ns'],1,2**63-1)
    integer(t['capacity'],1,4096);integer(t['window'],1,256)
    for prefix in ('rtt','aoi'):
        integer(t[prefix+'_good_ns'],0,2**63-2);integer(t[prefix+'_bad_ns'],t[prefix+'_good_ns']+1,2**63-1)
    q=fields(raw['quality'],'required horizon_ns period_ns')
    integer(q['required'],1,7);integer(q['horizon_ns'],1,2**63-1);integer(q['period_ns'],1,2**63-1)
    if not q['required']&1:raise ValueError('PDR is mandatory')
    if type(raw['nodes']) is not list or not 1<=len(raw['nodes'])<=4:raise ValueError('one to four nodes required')
    nodes=[]
    for n in raw['nodes']:
        names='slot node session epoch revision nonce_hex key_file bind_ip bind_port peer_ip peer_port policy'
        fields(n,names+(' clock_mapping' if 'clock_mapping' in n else ''))
        mapping=None
        if 'clock_mapping' in n:
            m=fields(n['clock_mapping'],'remote_domain_hex rate_ppm rate_evidence max_anchor_age_ns max_extrapolation_ns capacity')
            if type(m['remote_domain_hex']) is not str or not re.fullmatch('[0-9a-f]{32}',m['remote_domain_hex']):
                raise ValueError('canonical remote clock lifetime required')
            RateEvidence(m['rate_ppm'],m['rate_evidence'])
            integer(m['max_anchor_age_ns'],1,2**63-1);integer(m['max_extrapolation_ns'],1,2**63-1)
            integer(m['capacity'],1,64)
            mapping=tuple(m.items())
        integer(n['slot'],0,3)
        p=fields(n['policy'],'window min_count low_permille high_permille max_age_ms')
        policy=Policy(p['window'],p['min_count'],p['low_permille'],p['high_permille'],p['max_age_ms'])
        if policy.window!=raw['hardware_window']:raise ValueError('policy window must match compiled hardware window')
        monitor=MonitorSettings(n['node'],n['session'],n['epoch'],n['revision'],policy)
        if type(n['nonce_hex']) is not str or not re.fullmatch('[0-9a-f]{32}',n['nonce_hex']):raise ValueError('canonical 128-bit nonce hex required')
        nonce=bytes.fromhex(n['nonce_hex']);Context(n['node'],n['session'],1,nonce,0,r['count'])
        nodes.append(NodeDeployment(n['slot'],monitor,nonce,local_path(n['key_file']),
            validate_peer((n['bind_ip'],n['bind_port'])),validate_peer((n['peer_ip'],n['peer_port'])),mapping))
    for label,values in (('slot',[n.slot for n in nodes]),('node',[n.monitor.node for n in nodes]),
                         ('bind',[n.bind for n in nodes]),('key_file',[n.key_file for n in nodes])):
        if len(set(values))!=len(values):raise ValueError('duplicate '+label)
    return Deployment(helper,local_path(raw['identity_root']),raw['uio'],float(timeout),raw['hardware_window'],tuple(nodes),
        **r,timing=tuple(t.items()),quality_required=q['required'],quality_horizon_ns=q['horizon_ns'],quality_period_ns=q['period_ns'])


def load(path):
    path=Path(path)
    if path.stat().st_size>65536:raise ValueError('bounded deployment file required')
    raw=json.loads(path.read_text(encoding='utf8'),object_pairs_hook=unique_object)
    return parse(raw,path.parent)
