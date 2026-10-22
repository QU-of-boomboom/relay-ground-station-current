"""Explicit-peer UDP services for the authenticated remote batch contract.

No discovery, key distribution, automatic restart, or hardware access. Callers
own sockets and drive these bounded methods from one foreground event loop.
"""
from contextlib import contextmanager
import hashlib
import ipaddress
import socket
import threading
import time

from ledger_station import Journal
from quality_reference import integer
from remote_round_protocol import (Context, Message, DroneResponder, HostRound,
    GRANT, DATA, FACTS, RemoteFault, encode, decode, MAX_WIRE)
from remote_timed_sample import SensorSample, TimedSample, encode as encode_timed


class _QueueEmpty(Exception):
    pass


def validate_peer(peer):
    if type(peer) is not tuple or len(peer) != 2 or type(peer[0]) is not str:
        raise ValueError('explicit IPv4 peer and port required')
    address = ipaddress.IPv4Address(peer[0])
    integer(peer[1], 1, 65535)
    if str(address) != peer[0] or address.is_multicast or address.is_unspecified or int(address) == 0xffffffff:
        raise ValueError('unicast numeric IPv4 peer required')
    return peer


class _Service:
    def __init__(self, sock, peer, journal_path, *, clock_ns, role, node, session, nonce):
        self.peer = validate_peer(peer)
        if not callable(clock_ns):raise ValueError('monotonic clock required')
        if sock.family != socket.AF_INET or sock.type & socket.SOCK_DGRAM != socket.SOCK_DGRAM:
            raise ValueError('IPv4 datagram socket required')
        self.sock, self.clock = sock, clock_ns
        self.owner, self.busy, self.stopped = threading.get_ident(), False, False
        self.rejected = self.foreign = 0
        self.last_time = -1
        self.journal = Journal(journal_path)
        try:
            self.journal.append('header',dict(schema=1,role=role,node=node,session=session,
                nonce=nonce.hex(),peer=list(peer),deadline_origin='host_grant',
                board_verified=False,clock='host_monotonic' if role=='host' else 'node_monotonic'))
            sock.setblocking(False)
        except BaseException:
            self.journal.close();self.stopped=True;raise

    def _now(self):
        value=self.clock()
        integer(value,max(0,self.last_time),2**63-1)
        self.last_time=value
        return value

    @contextmanager
    def _operation(self):
        if threading.get_ident()!=self.owner or self.busy:
            raise RemoteFault('service requires nonreentrant owner thread')
        if self.stopped:raise RemoteFault('remote service stopped')
        self.busy=True
        try:yield
        except BaseException as error:
            self.stopped=True
            try:self.journal.append('abort',dict(error_type=type(error).__name__))
            except BaseException:pass
            raise
        finally:self.busy=False

    def _send(self, wire):
        # Intent is durable before the syscall; an unknown completion is never
        # silently promoted to a successful local transmission fact.
        self.journal.append('send_intent',dict(wire=wire.hex(),local_ns=self._now()))
        try:
            ok=self.sock.sendto(wire,self.peer)==len(wire)
            error=None
        except OSError as exc:
            ok=False;error=type(exc).__name__
        self.journal.append('send_result',dict(ok=ok,error=error,local_ns=self._now()))
        return ok

    def _receive(self):
        # Read the full UDP datagram before applying the much smaller protocol
        # cap. Windows raises WSAEMSGSIZE instead of returning a truncated prefix.
        try:wire,address=self.sock.recvfrom(65535)
        except BlockingIOError:raise _QueueEmpty from None
        now=self._now()
        if address!=self.peer:
            self.foreign+=1
            self.journal.append('foreign',dict(peer=list(address),local_ns=now,sha256=hashlib.sha256(wire).hexdigest()))
            return None,now
        try:message=decode(wire,self.key)
        except ValueError:
            self.rejected+=1
            self.journal.append('rejected',dict(local_ns=now,sha256=hashlib.sha256(wire).hexdigest(),bytes=len(wire)))
            return None,now
        self.journal.append('receive',dict(wire=wire.hex(),local_ns=now))
        return message,now

    def close(self,reason='NORMAL_STOP'):
        if threading.get_ident()!=self.owner or self.busy:
            raise RemoteFault('close requires idle owner thread')
        if self.journal is not None:
            self.stopped=True
            journal,self.journal=self.journal,None
            try:journal.append('stop',dict(reason=reason))
            finally:journal.close()


class RemoteDroneUdp(_Service):
    def __init__(self,sock,peer,journal_path,*,node,session,nonce,key,sample=None,
                 timed_sample=None,first_sequence=0,clock_ns=time.monotonic_ns):
        if (sample is None)==(timed_sample is None) or not callable(sample if sample is not None else timed_sample):
            raise ValueError('exactly one explicit application sampler required')
        self.responder=DroneResponder(node=node,session=session,nonce=nonce,key=key,first_sequence=first_sequence)
        self.key,self.sample=key,sample
        self.timed_sample=timed_sample
        super().__init__(sock,peer,journal_path,clock_ns=clock_ns,role='drone',node=node,session=session,nonce=nonce)

    def pump(self,limit=32):
        integer(limit,1,256)
        with self._operation():
            receipts=[]
            for _ in range(limit):
                try:message,received=self._receive()
                except _QueueEmpty:return tuple(receipts)
                if message is None:continue
                if message.kind!=GRANT:
                    self.rejected+=1;continue
                def timestamped(sequence):
                    sampled=self.timed_sample(sequence)
                    if not isinstance(sampled,SensorSample):
                        raise RemoteFault('explicit sensor generation evidence required')
                    if sampled.fresh_after_grant and sampled.generated_ns<received:
                        raise RemoteFault('fresh sample predates grant receipt')
                    record=TimedSample(sampled.clock_domain,sampled.generated_ns,
                                       received,self._now(),sampled.payload)
                    return encode_timed(record),sampled.fresh_after_grant
                receipt=self.responder.grant(message,self.sample if self.timed_sample is None else timestamped,self._send)
                self.journal.append('grant_result',dict(round=message.context.round,receipt=receipt))
                receipts.append(receipt)
            return tuple(receipts)


class RemoteHostUdp(_Service):
    def __init__(self,sock,peer,journal_path,*,node,session,nonce,key,budget_ns,
                 facts_timeout_ns,first_sequence=0,clock_ns=time.monotonic_ns):
        initial=Context(node,session,1,nonce,first_sequence,1)
        # Validate the full static contract before opening a journal/socket mode.
        encode(Message(GRANT,initial),key)
        HostRound(initial,started_ns=0,budget_ns=budget_ns,facts_timeout_ns=facts_timeout_ns)
        self.node,self.session,self.nonce,self.key=node,session,nonce,key
        self.budget,self.facts_timeout=budget_ns,facts_timeout_ns
        self.next_sequence,self.next_round=first_sequence,1
        self.active=self.previous=None
        self.grant_wire=None;self.retries=0
        super().__init__(sock,peer,journal_path,clock_ns=clock_ns,role='host',node=node,session=session,nonce=nonce)

    def begin(self,count):
        with self._operation():
            if self.active is not None and self.active.closed is None:
                raise RemoteFault('one remote round at a time')
            context=Context(self.node,self.session,self.next_round,self.nonce,self.next_sequence,count)
            wire=encode(Message(GRANT,context),self.key)
            started=self._now()
            # Closure commits only closed_ns-1. A coarse clock may legitimately
            # give the next grant exactly closed_ns; it is still past that watermark.
            if self.active and started<self.active.closed.closed_ns:
                raise RemoteFault('grant clock precedes previous round closure')
            self.previous=self.active
            self.active=HostRound(context,started_ns=started,budget_ns=self.budget,facts_timeout_ns=self.facts_timeout)
            self.grant_wire=wire;self.retries=0
            self.journal.append('round_begin',dict(round=context.round,base=context.base,count=count,
                started_ns=started,deadline_ns=self.active.deadline))
            if not self._send(wire):raise RemoteFault('grant local send failed')
            self.next_sequence+=count;self.next_round+=1
            return context

    def retry_facts(self):
        with self._operation():
            if self.active is None or self.active.closed is not None or self.active.mask is not None:
                raise RemoteFault('no outstanding facts request')
            if self.retries>=3:raise RemoteFault('bounded grant retry limit reached')
            now=self._now()
            if now>=self.active.timeout:raise RemoteFault('facts timeout; no grant retry')
            self.retries+=1
            return self._send(self.grant_wire)

    def _late_previous(self,message):
        previous=self.previous
        if previous is None or message.context!=previous.context:return False
        if message.kind==FACTS and message.send_mask!=previous.mask:
            raise RemoteFault('late conflicting facts for previous round')
        if message.kind==DATA:
            if not previous.mask & (1<<message.index):raise RemoteFault('late data contradicts previous failed send')
            old=previous.received.get(message.index)
            if old and old[1:]!=(message.payload,message.generated_after_grant):
                raise RemoteFault('late conflicting data for previous round')
        return True

    def pump(self,limit=256):
        integer(limit,1,65536)
        with self._operation():
            if self.active is None:raise RemoteFault('begin a round before pumping')
            if self.active.closed is not None:return self.active.closed
            for _ in range(limit):
                sampled=self._now()
                try:message,observed=self._receive()
                except _QueueEmpty:
                    closed=self.active.empty_queue(sampled)
                    if closed is not None:
                        self.journal.append('round_closed',dict(round=closed.context.round,
                            started_ns=closed.started_ns,deadline_ns=closed.deadline_ns,closed_ns=closed.closed_ns,
                            send_mask=closed.send_mask,outcomes=closed.outcomes,
                            received=[dict(index=i,observed_ns=t,payload=p.hex(),generated_after_grant=g)
                                      for i,t,p,g in closed.received]))
                    return closed
                if message is None:continue
                if message.kind not in (DATA,FACTS):self.rejected+=1;continue
                if self._late_previous(message):continue
                self.active.receive(message,observed)
            # Explicitly unfinished drain; no watermark or loss inference.
            self.journal.append('drain_pending',dict(round=self.active.context.round,limit=limit,local_ns=self._now()))
            return None
