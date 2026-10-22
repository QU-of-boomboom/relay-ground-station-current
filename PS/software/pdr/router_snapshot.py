"""Local informational RSSI snapshots; never grant timed RF or relay eligibility."""
import json
import os
from pathlib import Path
import re
import tempfile

from openwrt_rssi import MAX_BYTES, mac_address, unique_object
from quality_reference import integer


def publish(path, state, now):
    integer(now,0,2**63-1)
    path=Path(path)
    data=json.dumps(dict(schema=1,published_ns=now,state=state),
                    separators=(',',':'),allow_nan=False).encode('utf8')
    if len(data)>MAX_BYTES:raise ValueError('snapshot too large')
    fd,temporary=tempfile.mkstemp(prefix='.router_status_',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


class RouterSnapshotReader:
    def __init__(self,path,run_id,nodes,*,max_age_ns=5_000_000_000):
        if type(run_id) is not str or not re.fullmatch('[0-9a-f]{32}',run_id):
            raise ValueError('explicit collector run_id required')
        nodes=tuple(nodes)
        if not 1<=len(nodes)<=4 or len(set(nodes))!=len(nodes):raise ValueError('distinct deployed nodes required')
        for node in nodes:integer(node,1,2**32-1)
        integer(max_age_ns,1,60_000_000_000)
        self.path,self.run_id,self.nodes=Path(path),run_id,nodes
        self.max_age=max_age_ns;self.sequence=0;self.last_now=-1

    def unavailable(self,reason):
        return dict(available=False,reason=reason,run_id=self.run_id,
                    nodes=[dict(node=node,mac=None,rssi_dbm=None,status='UNAVAILABLE') for node in self.nodes],
                    measurement_time_verified=False,realtime_eligible=False,router_verified=False)

    def read(self,now):
        try:
            integer(now,max(0,self.last_now),2**63-1);self.last_now=now
            if self.path.is_symlink() or not self.path.is_file():return self.unavailable('SNAPSHOT_MISSING')
            with self.path.open('rb') as stream:data=stream.read(MAX_BYTES+1)
            if len(data)>MAX_BYTES:raise ValueError('snapshot size')
            row=json.loads(data,object_pairs_hook=unique_object,
                parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
            if type(row) is not dict or set(row)!={'schema','published_ns','state'} or type(row['schema']) is not int or row['schema']!=1:
                raise ValueError('snapshot schema')
            stamp=row['published_ns'];integer(stamp,0,now)
            if now-stamp>=self.max_age:return self.unavailable('SNAPSHOT_EXPIRED')
            state=row['state']
            if type(state) is not dict or state.get('run_id')!=self.run_id:raise ValueError('collector generation')
            for field in ('realtime_eligible','measurement_time_verified','router_verified'):
                if state.get(field) is not False:raise ValueError('unverified RF required')
            for field in ('source_live','stopped'):
                if type(state.get(field)) is not bool:raise ValueError('strict status boolean')
            sequence=state.get('sequence');integer(sequence,self.sequence,2**63-1)
            if not state['source_live'] or state['stopped']:return self.unavailable('COLLECTOR_UNAVAILABLE')
            if sequence<1:raise ValueError('live poll sequence must be positive')
            if state.get('reason') is not None or type(state.get('consecutive_failures')) is not int or state['consecutive_failures']!=0:
                raise ValueError('inconsistent live collector')
            latest=state.get('latest')
            if type(latest) is not dict or latest.get('run_id')!=self.run_id or type(latest.get('sequence')) is not int or latest['sequence']!=sequence:
                raise ValueError('latest generation/sequence')
            for field in ('realtime_eligible','measurement_time_verified','router_verified'):
                if latest.get(field) is not False:raise ValueError('unverified RF required')
            start,finish=latest.get('poll_started_ns'),latest.get('poll_finished_ns')
            integer(start,0,stamp);integer(finish,start,stamp)
            if now-finish>=self.max_age:return self.unavailable('OBSERVATION_EXPIRED')
            observations=latest.get('observations')
            if type(observations) is not list or not 1<=len(observations)<=1024:raise ValueError('bounded observations')
            found={};macs=set()
            for observation in observations:
                if type(observation) is not dict:raise ValueError('observation schema')
                node=observation.get('node');integer(node,1,2**32-1)
                mac=mac_address(observation.get('mac'))
                if node in found or mac in macs:raise ValueError('duplicate mapping')
                macs.add(mac)
                if observation.get('measurement_time_ns') is not None or observation.get('measurement_time_verified') is not False or observation.get('realtime_eligible') is not False:
                    raise ValueError('RF time not verified')
                signal=observation.get('rssi_dbm');status=observation.get('status')
                if status=='PRESENT_UNTIMED':integer(signal,-127,-1)
                elif status not in ('NOT_LISTED','SIGNAL_UNAVAILABLE') or signal is not None:raise ValueError('RSSI status')
                found[node]=dict(node=node,mac=mac,rssi_dbm=signal,status=status)
            result=self.unavailable(None)
            result.update(available=True,sequence=sequence,published_ns=stamp,poll_finished_ns=finish,
                nodes=[found.get(node,dict(node=node,mac=None,rssi_dbm=None,status='NOT_MAPPED')) for node in self.nodes])
            self.sequence=sequence
            return result
        except (OSError,ValueError,TypeError,KeyError,UnicodeError,RecursionError):
            return self.unavailable('SNAPSHOT_INVALID')
