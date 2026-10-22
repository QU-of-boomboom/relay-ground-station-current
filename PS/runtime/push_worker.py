"""Board autonomous telemetry receiver; no GRANT dependency or source abort."""
import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import queue
import signal
import socket
import sys
import threading
import time
import traceback

from push_protocol import VERSION,decode,encode
from performance import Performance


class EventOutput:
    """Keep local evidence and request drain when the SSH output disappears."""
    def __init__(self, log, stop, stream):
        self.log, self.stop, self.stream = log, stop, stream
        self.disconnected = False

    def __call__(self, row):
        row['board_monotonic_ns'] = time.monotonic_ns()
        line = json.dumps(row)+'\n'
        self.log.write(line)
        self.log.flush()
        if not self.disconnected:
            try:
                self.stream.write(line)
                self.stream.flush()
            except (BrokenPipeError, OSError):
                self.disconnected = True
                self.stop.set()


class Inbox:
    """Bounded network owner, independent of PL transactions and webpage polling."""
    def __init__(self,nodes,keys):
        self.nodes,self.keys=nodes,keys;self.q=queue.Queue(maxsize=4096)
        self.stop=threading.Event();self.error=None;self.dropped=0;self.rejected=0
        self.latest={};self.lock=threading.Lock()
        self.watermark=self.closed_watermark=time.monotonic_ns()
        self.high_watermark=0
        self.ready=threading.Event();self.thread=threading.Thread(target=self.run,daemon=True)

    def receive(self,n,k,w,addr,observed):
        if addr!=n.peer:return
        try:m=decode(w,k)
        except ValueError:self.rejected+=1;return
        if ((m['node'],m['session'],m['epoch'],m['challenge']) !=
            (n.monitor.node,n.monitor.session,n.monitor.epoch,n.nonce.hex())):
            self.rejected+=1;return
        if m['kind'] not in ('data','echo'):return
        if m['kind']=='data':
            with self.lock:
                previous=self.latest.get(n.slot)
                if previous is None or m['seq']>previous[0]:
                    self.latest[n.slot]=(m['seq'],observed)
        self.event((m['kind'],n.slot,m,observed,None))

    def last_received(self,slot):
        with self.lock:
            value=self.latest.get(slot)
            return None if value is None else value[1]

    def event(self,row):
        with self.lock:
            try:
                self.q.put_nowait(row);self.high_watermark=max(self.high_watermark,self.q.qsize())
            except queue.Full:self.dropped+=1

    def take_events(self,limit=512):
        # Only close time through a completed network scan after its queued
        # observations have been removed for processing. Never overtake backlog.
        rows=[]
        with self.lock:
            for _ in range(limit):
                try:rows.append(self.q.get_nowait())
                except queue.Empty:break
            if self.q.empty():self.closed_watermark=self.watermark
            return rows,self.closed_watermark

    def run(self):
        sockets=[];due=0;seq=0
        try:
            for n in self.nodes:
                s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
                sockets.append(s)  # Own it before bind, including bind failure.
                s.bind(n.bind);s.setblocking(False)
            self.ready.set()
            while not self.stop.is_set():
                now=time.monotonic_ns()
                if now>=due:
                    for n,k,s in zip(self.nodes,self.keys,sockets):
                        m=dict(v=VERSION,kind='probe',node=n.monitor.node,session=n.monitor.session,
                            epoch=n.monitor.epoch,challenge=n.nonce.hex(),seq=seq)
                        t=time.monotonic_ns()
                        try:ok=s.sendto(encode(m,k),n.peer)>0
                        except OSError:ok=False
                        self.event(('probe',n.slot,seq,t,ok))
                    seq+=1;due=now+250_000_000
                for n,k,s in zip(self.nodes,self.keys,sockets):
                    for _ in range(64):
                        try:w,addr=s.recvfrom(65535)
                        except (BlockingIOError,ConnectionResetError):break
                        observed=time.monotonic_ns()
                        self.receive(n,k,w,addr,observed)
                with self.lock:self.watermark=time.monotonic_ns()
                self.stop.wait(.001)
        except BaseException:self.error=traceback.format_exc();self.ready.set()
        finally:
            for s in sockets:s.close()

    def close(self):
        self.stop.set();self.thread.join(3)
        if self.thread.is_alive():raise RuntimeError('UDP receiver stop unconfirmed')


def main():
    p=argparse.ArgumentParser()
    for flag in ('candidate','config','out','mapping'):p.add_argument('--'+flag,type=Path,required=True)
    p.add_argument('--duration',type=int,default=0,help='0: until STOP or control connection closes')
    p.add_argument('--native-library',required=True);p.add_argument('--native-sha256',required=True)
    a=p.parse_args()
    if not 0<=a.duration<=3600:raise ValueError('receiver lifetime: 0 or 1..3600 seconds')
    sys.path.append(str(a.candidate/'software/pdr'))
    from remote_deployment import load
    from remote_station_runtime import read_keys,reserve_identities
    from physical_transport import PhysicalBusLease,PhysicalSlotTransport,PhysicalQualityTransport
    from native_register import NativeRegister
    from online_station import ContinuousStation
    from grouped_journal import GroupedJournal
    from push_settlement import PushSettlement
    from timing_metrics import TimingMetrics,GenerationBounds
    from link_service_client import LinkServiceClient
    from hardware_display import quality_record,alarm_record
    from alarm_snapshot_client import AlarmSnapshotClient,SnapshotUnavailable

    cfg=load(a.config);keys=read_keys(cfg)
    for n,c in zip(cfg.nodes,reserve_identities(cfg)):c.consume('host',n.monitor.node,n.monitor.session,n.nonce)
    a.out.mkdir();log=(a.out/'dashboard.jsonl').open('x');stop=threading.Event()
    for name in ('SIGTERM', 'SIGINT', 'SIGHUP'):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), lambda _sig, _frame: stop.set())
    def commands():
        for line in sys.stdin:
            if line.strip()=='STOP':stop.set()
        stop.set()
    threading.Thread(target=commands,daemon=True).start()
    emit = EventOutput(log, stop, sys.stdout)
    raw=inbox=client=None;stations={};timings={};readers={};anchors={};quality={};perf=Performance()
    failed={};exit_code=0
    try:
        raw=NativeRegister(a.native_library,cfg.uio,sha256=a.native_sha256)
        for method in ('read32','write32'):perf.wrap(raw,method,'raw_'+method)
        if raw.native_guarded:
            for method in ('slot_epoch','guarded_transfer'):perf.wrap(raw,method,'native_'+method)
        bus=PhysicalBusLease(raw)
        domain='push:'+str(cfg.nodes[0].monitor.epoch)
        client=LinkServiceClient(PhysicalQualityTransport(bus),clock_domain=domain)
        perf.wrap(client,'transact','quality_transaction')
        for n in cfg.nodes:
            started=time.monotonic_ns();directory=a.out/('slot%d'%n.slot);directory.mkdir()
            engine=PushSettlement(node=n.monitor.node,session=n.monitor.session,started_ns=started,
                qualification_window=n.monitor.policy.window,
                deadline_ns=150_000_000,capacity=256,source_timeout_ns=cfg.source_timeout_ns,
                statistics_age_ns=cfg.statistics_age_ns)
            stations[n.slot]=ContinuousStation(directory,n.monitor,engine,lambda slot=n.slot:PhysicalSlotTransport(bus,slot),
                                              journal_factory=GroupedJournal)
            perf.wrap(stations[n.slot].journal,'append','journal_append')
            perf.wrap(stations[n.slot].journal,'flush','journal_flush')
            perf.wrap(stations[n.slot].client,'settle','control_transaction')
            timings[n.slot]=TimingMetrics(node=n.monitor.node,session=n.monitor.session,clock_domain=domain,
                                           started_ns=started,**dict(cfg.timing))
            readers[n.slot]=AlarmSnapshotClient(PhysicalSlotTransport(bus,n.slot),0);anchors[n.slot]={}
            perf.wrap(readers[n.slot],'read_snapshot','alarm_snapshot')
        inbox=Inbox(cfg.nodes,keys);inbox.thread.start()
        if not inbox.ready.wait(3) or inbox.error:raise RuntimeError(inbox.error or 'UDP receiver startup timeout')
        emit(dict(kind='ready',state='receiving',pid=os.getpid(),mode='autonomous_push',
                  nodes=[n.monitor.node for n in cfg.nodes],alarm_source='FPGA coherent snapshot'))
        end=time.monotonic()+a.duration if a.duration else float('inf')
        stopping=None;expiry=None;next_view=next_quality=0
        while True:
            now=time.monotonic()
            if (stop.is_set() or now>=end) and stopping is None:
                stopping=now;inbox.close();emit(dict(kind='state',state='draining'))
                client.cancel_unified()
            if inbox.error:raise RuntimeError(inbox.error)
            if inbox.dropped:raise RuntimeError('bounded receive queue overflow; reception evidence incomplete')
            events,watermark=inbox.take_events()
            for kind,slot,value,observed,ok in events:
                if slot in failed:continue
                station=stations[slot];timing=timings[slot];engine=station.engine;t=time.monotonic_ns()
                perf.maximum('queue_event_age_ns',t-observed)
                if kind=='probe':
                    timing.probe_sent(value,ok,t,observed_ns=observed)
                    if ok:anchors[slot][value]=observed
                    anchors[slot]={s:v for s,v in anchors[slot].items() if observed-v<2_000_000_000}
                elif kind=='echo':timing.reply(value['node'],value['session'],value['seq'],observed,t)
                else:
                    accepted=engine.ingest(value,observed,t)
                    station.journal.append('push_input',dict(message=value,observed_ns=observed))
                    if accepted:
                        anchor=anchors[slot].get(value['probe'])
                        # Synthetic sample is generated in sender's periodic tick AFTER
                        # receiving the echoed probe. Pure causality; no RTT/2/clock guess.
                        bounds=GenerationBounds(anchor,observed,domain) if anchor is not None and anchor<=observed else None
                        timing.state(value['node'],value['session'],value['seq'],bounds,observed,time.monotonic_ns())
            if expiry is None:
                # After close there can be no later RX observation. The existing
                # 150 ms reorder grace still applies to every known send fact.
                if stopping is not None and inbox.q.empty():watermark=time.monotonic_ns()
                for n in cfg.nodes:
                    station=stations[n.slot];t=time.monotonic_ns()
                    e=station.engine
                    if e.cursor in e.fact_times and e.fact_times[e.cursor]+e.budget<=watermark:
                        emit(dict(kind='operation',name='settle',slot=n.slot,phase='begin'))
                        station.advance(watermark,watermark,t,max_outcomes=4)
                        emit(dict(kind='operation',name='settle',slot=n.slot,phase='complete'))
                    else:
                        # Empty watermark advancement requires no MMIO or SD fsync.
                        assert not e.advance(watermark,watermark,t,max_outcomes=4)
                if stopping is not None and not any(s.engine.facts for s in stations.values()) and inbox.q.empty():
                    for s in stations.values():
                        s.verify_counter_receipt();s.close('USER_STOP')
                    for t in timings.values():t.stop('USER_STOP')
                    expiry=time.monotonic();emit(dict(kind='state',state='observing_expiry'))
                elif stopping is not None and time.monotonic()-stopping>3:
                    raise RuntimeError('push pending evidence not settled on stop')
            now=time.monotonic()
            if expiry is None and stopping is None and now>=next_quality:
                evaluated=[]
                for n in cfg.nodes:
                    if stop.is_set() or time.monotonic()>=end:break
                    emit(dict(kind='operation',name='quality',slot=n.slot,phase='begin'))
                    quality[n.slot]=quality_record(client.transact(stations[n.slot],timings[n.slot],
                        slot=n.slot,required=cfg.quality_required,horizon_ns=cfg.quality_horizon_ns))
                    quality[n.slot]['alarm_sample']=alarm_record(client,n.slot,stop,
                        clock_ns=time.monotonic_ns,deadline_ns=quality[n.slot]['deadline_ns'])
                    evaluated.append(dict(node=n.monitor.node,value=quality[n.slot]))
                    emit(dict(kind='operation',name='quality',slot=n.slot,phase='complete'))
                emit(dict(kind='quality',nodes=evaluated))
                next_quality=time.monotonic()+cfg.quality_period_ns/1e9
            if now>=next_view:
                rows=[]
                for n in cfg.nodes:
                    s=n.monitor;station=stations[n.slot];e=station.engine;t=time.monotonic_ns()
                    emit(dict(kind='operation',name='counter_receipt',slot=n.slot,phase='begin'))
                    receipt,receipt_ns=station.counter_receipt()
                    emit(dict(kind='operation',name='counter_receipt',slot=n.slot,phase='complete'))
                    if not receipt.accepted:raise RuntimeError('FPGA counter query rejected')
                    try:
                        emit(dict(kind='operation',name='alarm_read',slot=n.slot,phase='begin'))
                        alarm=asdict(readers[n.slot].read_snapshot())
                        emit(dict(kind='operation',name='alarm_read',slot=n.slot,phase='complete'))
                        if tuple(alarm['active'])!=(s.node,s.session,s.epoch,s.revision):raise RuntimeError('snapshot identity mismatch')
                        alarm.pop('payload')
                    except SnapshotUnavailable:alarm=None
                    received=inbox.last_received(n.slot)
                    observed_now=time.monotonic_ns()
                    linked=received is not None and observed_now-received<cfg.source_timeout_ns
                    backlog=any(v+e.budget<=observed_now for v in e.fact_times.values())
                    metrics=timings[n.slot].status(time.monotonic_ns())
                    rows.append(dict(node=s.node,slot=n.slot,session=s.session,peer=n.peer,
                        fpga=asdict(receipt),alarm=alarm,timing=metrics,
                        unified_alarm=client.unified_snapshot(n.slot),
                        counter_source='durably_confirmed_fpga_receipt',counter_age_ns=time.monotonic_ns()-receipt_ns,
                        ps=dict(sent=e.sent,delivered=e.delivered,settled=station.confirmed,pending=len(e.facts)),
                        source_error=None if linked or stopping is not None else '暂未收到新数据；继续监听，恢复后自动接收',
                        network_last_received_ns=received,settlement_backlog=backlog,
                        unknown_omitted=e.omitted,receiving=stopping is None,
                        measurement='proven_send_reception; not grant deadline'))
                emit(dict(kind='sample',state='observing_expiry' if expiry else 'draining' if stopping else 'receiving',
                          mode='autonomous_push',nodes=rows,network_rejected=inbox.rejected,
                          queue_depth=inbox.q.qsize(),queue_high_watermark=inbox.high_watermark))
                next_view=time.monotonic()+.5
            if expiry is not None and time.monotonic()-expiry>=5:break
            for station in stations.values():
                if not station.closed:station.journal.flush_due()
            time.sleep(.002)
    except BaseException as e:
        exit_code=1;(a.out/'failure.txt').write_text(traceback.format_exc());emit(dict(kind='error',state='failed',error=str(e)))
    finally:
        errors=[]
        for obj in [inbox,client,*stations.values(),raw]:
            if obj is not None:
                try:obj.close()
                except BaseException as e:errors.append(str(e))
        if errors:exit_code=1
        if inbox:perf.maximum('queue_high_watermark',inbox.high_watermark)
        try:
            emit(dict(kind='performance',**perf.report()))
            emit(dict(kind='done',state='failed' if exit_code else 'stopped',exit_code=exit_code,
                      cleanup_errors=errors,source_failures=failed,partial_run=False,
                      control_output_disconnected=emit.disconnected))
        finally:
            log.close()
    return exit_code


if __name__=='__main__':raise SystemExit(main())
