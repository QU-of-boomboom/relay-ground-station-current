"""Explicit relay feedback state; command delivery never implies application."""
from dataclasses import asdict,dataclass
from pathlib import Path
from ledger_station import Journal
from quality_reference import integer


class RelayFault(RuntimeError):pass
class RelayNotReady(RuntimeError):pass


@dataclass(frozen=True)
class RelayCommand:
    relay_id:int
    device_generation:int
    controller_session:int
    command_id:int
    enabled:bool
    target_node:int


class RelayController:
    def __init__(self,*,relay_id,device_generation,controller_session,started_ns,
                 acknowledgement_timeout_ns,cooldown_ns,status_max_age_ns):
        integer(relay_id,1,2**32-1);integer(device_generation,1,2**64-1);integer(controller_session,1,2**64-1)
        integer(started_ns,0,2**63-1);integer(acknowledgement_timeout_ns,1,2**63-1)
        integer(cooldown_ns,0,2**63-1);integer(status_max_age_ns,1,2**63-1)
        self.relay_id,self.generation,self.session=relay_id,device_generation,controller_session
        self.now=started_ns;self.timeout=acknowledgement_timeout_ns;self.cooldown=cooldown_ns;self.max_age=status_max_age_ns
        self.pending=None;self.deadline=None;self.last_report=None;self.report_sequence=-1
        self.applied=0;self.next_command=1;self.actual=None;self.cooldown_until=started_ns
        self.stopped=None

    def stop(self,reason):
        if type(reason) is not str or not reason:raise ValueError('explicit stop reason required')
        if self.stopped is None:self.stopped=reason

    def fault(self,reason):self.stop(reason);raise RelayFault(reason)

    def _time(self,now):
        if self.stopped:raise RelayFault('relay run stopped: '+self.stopped)
        try:integer(now,self.now,2**63-1)
        except ValueError:self.fault('clock invalid/regressed')
        self.now=now
        if self.pending is not None and now>=self.deadline:self.fault('execution confirmation timed out; actual state unknown')

    def status(self,now_ns):
        if not self.stopped:
            try:self._time(now_ns)
            except RelayFault:pass
        else:integer(now_ns,self.now,2**63-1)
        valid=(not self.stopped and self.actual is not None and self.pending is None and
               self.last_report is not None and now_ns-self.last_report<self.max_age)
        return dict(state='UNKNOWN' if self.stopped else 'WAIT_CONFIRM' if self.pending else
                    'CONFIRMED' if valid else 'UNOBSERVED',confirmed_valid=bool(valid),
                    actual=None if not valid else dict(enabled=self.actual[0],target_node=self.actual[1]),
                    applied_command_id=self.applied,pending_command_id=None if self.pending is None else self.pending.command_id,
                    reason=self.stopped,cooldown_remaining_ns=max(0,self.cooldown_until-now_ns),board_verified=False)

    def request(self,enabled,target_node,now_ns,*,permitted):
        self._time(now_ns)
        if type(enabled) is not bool or type(permitted) is not bool:raise ValueError('explicit boolean state and permission')
        integer(target_node,0,2**32-1)
        if enabled!=(target_node!=0):raise ValueError('ON requires target, OFF requires target zero')
        if not permitted:raise RelayNotReady('action not permitted by caller')
        if not self.status(now_ns)['confirmed_valid']:raise RelayNotReady('fresh confirmed baseline required')
        if now_ns<self.cooldown_until:raise RelayNotReady('confirmation cooldown active')
        if self.next_command>2**64-1 or now_ns>2**63-1-self.timeout:self.fault('command/time space exhausted')
        value=RelayCommand(self.relay_id,self.generation,self.session,self.next_command,enabled,target_node)
        self.next_command+=1;self.pending=value;self.deadline=now_ns+self.timeout
        return value

    def observe(self,report,now_ns,*,evidence_since_ns=None):
        self._time(now_ns)
        if evidence_since_ns is None:evidence_since_ns=now_ns
        try:integer(evidence_since_ns,0,now_ns)
        except ValueError:self.fault('invalid feedback evidence interval')
        keys={'relay_id','device_generation','controller_session','report_sequence','applied_command_id','enabled','target_node'}
        if type(report) is not dict or set(report)!=keys:self.fault('feedback schema')
        try:
            for key in ('relay_id','target_node'):integer(report[key],0,2**32-1)
            for key in ('device_generation','controller_session','report_sequence','applied_command_id'):integer(report[key],0,2**64-1)
            if type(report['enabled']) is not bool or report['enabled']!=(report['target_node']!=0):raise ValueError('actual state')
        except ValueError:self.fault('invalid feedback field')
        if (report['relay_id'],report['controller_session'])!=(self.relay_id,self.session):return 'FOREIGN'
        if report['device_generation']!=self.generation:self.fault('device generation changed')
        if report['report_sequence']<=self.report_sequence:return 'DUPLICATE_OR_OLD'
        applied=report['applied_command_id'];actual=(report['enabled'],report['target_node'])
        if self.pending is not None and applied==self.pending.command_id:
            if actual!=(self.pending.enabled,self.pending.target_node):self.fault('execution feedback contradicts command')
            self.applied=applied;self.actual=actual;self.pending=None
            if now_ns>2**63-1-self.cooldown:self.fault('cooldown time exhausted')
            self.cooldown_until=now_ns+self.cooldown;receipt='APPLIED'
        elif applied==self.applied:
            if self.actual is not None and actual!=self.actual:self.fault('confirmed state changed without command')
            self.actual=actual;receipt='BASELINE' if self.last_report is None else 'HEARTBEAT'
        else:self.fault('unexpected applied command')
        self.report_sequence=report['report_sequence'];self.last_report=evidence_since_ns
        return receipt


class RelayRuntime:
    def __init__(self,directory,controller,send_command):
        if not isinstance(controller,RelayController) or not callable(send_command):raise ValueError('controller/transport')
        self.directory=Path(directory);self.controller=controller;self.send_command=send_command
        self.lock=None;self.journal=None;self.closed=False
        try:
            self.lock=(self.directory/'relay.lock').open('xb')
            if any(p.name!='relay.lock' for p in self.directory.iterdir()):raise RelayFault('new empty relay run directory required')
            self.journal=Journal(self.directory/'relay.jsonl')
            self.journal.append('header',dict(schema=1,relay_id=controller.relay_id,
                device_generation=controller.generation,controller_session=controller.session))
        except BaseException:
            controller.stop('START_FAILED');self.close();raise

    def dispatch(self,enabled,target_node,now_ns,*,permitted):
        if self.closed:raise RelayFault('runtime closed')
        # Ordinary lack of permission/cooldown is a rejection before any intent.
        command=self.controller.request(enabled,target_node,now_ns,permitted=permitted)
        try:
            self.journal.append('intent',dict(now_ns=now_ns,command=asdict(command)))
            result=self.send_command(command)
            if result is False:raise RelayFault('send rejected')
            self.journal.append('sent',dict(command_id=command.command_id))
            return command
        except BaseException:
            self.controller.stop('SEND_OR_STORAGE_UNKNOWN');raise

    def feedback(self,report,now_ns,*,evidence_since_ns=None):
        if self.closed:raise RelayFault('runtime closed')
        try:
            row=dict(now_ns=now_ns,report=report)
            if evidence_since_ns is not None:row['evidence_since_ns']=evidence_since_ns
            self.journal.append('feedback',row)
            return self.controller.observe(report,now_ns,evidence_since_ns=evidence_since_ns)
        except BaseException:
            self.controller.stop('FEEDBACK_OR_STORAGE_FAILED');raise

    def close(self):
        if self.closed:return
        self.closed=True;self.controller.stop('RUNTIME_STOPPED')
        try:
            if self.journal is not None:
                try:self.journal.append('stop',dict(reason=self.controller.stopped,confirmed_valid=False))
                finally:self.journal.close()
        finally:
            if self.lock is not None:
                self.lock.close();(self.directory/'relay.lock').unlink();self.lock=None
