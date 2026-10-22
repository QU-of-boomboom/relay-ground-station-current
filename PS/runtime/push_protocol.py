"""Authenticated autonomous telemetry v1. Probes never authorize DATA sends.

PDR here is reception completeness of proven sends, with a 150 ms reorder
settlement window after local evidence arrival; it is NOT grant-latency PDR.
"""
from collections import deque
import hashlib
import hmac
import json
import secrets
import socket
import time

VERSION = 'GS_PUSH_1'
HISTORY = 128


def integer(x, lo=0, hi=2**63-1):
    if type(x) is not int or not lo <= x <= hi: raise ValueError('integer range')


def validate(m):
    if type(m) is not dict:raise ValueError('object required')
    common={'v','kind','node','session','epoch','challenge','seq'}
    extra={'generated_ns','probe','base','results','synthetic'} if m.get('kind')=='data' else set()
    if set(m)!=common|extra or m['v']!=VERSION or m['kind'] not in ('data','probe','echo'):
        raise ValueError('push wire schema')
    for key in ('node','session','epoch','seq'): integer(m[key])
    if not 1<=m['node']<2**32 or not m['session']: raise ValueError('identity')
    if type(m['challenge']) is not str or len(m['challenge'])!=32:
        raise ValueError('challenge')
    bytes.fromhex(m['challenge'])
    if m['kind']=='data':
        integer(m['generated_ns']);integer(m['probe'],-1);integer(m['base'])
        if m['synthetic'] is not True or type(m['results']) is not list or len(m['results'])>HISTORY:
            raise ValueError('explicit synthetic profile and bounded history required')
        if any(type(v) is not bool for v in m['results']) or m['base']+len(m['results'])!=m['seq']:
            raise ValueError('completed attempt history must end before this DATA')
    return m


def encode(m,key):
    validate(m)
    if type(key) is not bytes or len(key)!=32: raise ValueError('32 byte key')
    body=json.dumps(m,sort_keys=True,separators=(',',':')).encode()
    return hmac.digest(key,body,'sha256')+body


def decode(wire,key):
    if not 33<=len(wire)<=4096 or not hmac.compare_digest(wire[:32],hmac.digest(key,wire[32:],'sha256')):
        raise ValueError('size/authentication')
    def unique(pairs):
        d={}
        for k,v in pairs:
            if k in d:raise ValueError('duplicate key')
            d[k]=v
        return d
    try: return validate(json.loads(wire[32:],object_pairs_hook=unique))
    except (TypeError,KeyError,UnicodeError,json.JSONDecodeError) as e:raise ValueError('malformed push packet') from e


def next_send_deadline(previous, now, period):
    """Keep the periodic schedule despite wake-up jitter; skip missed intervals."""
    following=previous+period
    return following if following>now else now+period


class AutonomousSender:
    """Lives independently of dashboard receive sessions. No hardware judgment."""
    def __init__(self,node,session,key,bind,peer,period=.1):
        if not .02<=period<=10:raise ValueError('sender period')
        self.node,self.session,self.key,self.bind,self.peer=node,session,key,bind,peer
        self.period=period;self.seq=0;self.results=deque(maxlen=HISTORY)
        self.epoch=0;self.challenge='0'*32;self.probe=-1
        self.sent=self.local_failures=self.rejected=0;self.error=None;self.running=False

    def packet(self,kind,seq):
        return dict(v=VERSION,kind=kind,node=self.node,session=self.session,
                    epoch=self.epoch,challenge=self.challenge,seq=seq)

    def accept_probe(self,m):
        if m['kind']!='probe' or (m['node'],m['session'])!=(self.node,self.session):return False
        if m['epoch']<self.epoch:return False
        if m['epoch']==self.epoch and (m['challenge']!=self.challenge or m['seq']<=self.probe):return False
        self.epoch,self.challenge,self.probe=m['epoch'],m['challenge'],m['seq']
        return True

    def status(self):
        return dict(node=self.node,session=self.session,independent=True,running=self.running,
                    period_ms=self.period*1000,attempts=self.seq,sent=self.sent,local_failures=self.local_failures,error=self.error)

    def run(self,stop,journal=None):
        sock=None;due=time.monotonic();self.running=True
        try:
            while not stop.is_set():
                if sock is None:
                    try:
                        sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(self.bind);sock.setblocking(False)
                        self.error=None
                    except OSError as e:
                        self.error=str(e)
                        if sock:sock.close()
                        sock=None;stop.wait(1);continue
                for _ in range(32):
                    try:w,addr=sock.recvfrom(65535)
                    except (BlockingIOError,ConnectionResetError):break
                    except OSError as e:
                        self.error=str(e);sock.close();sock=None;break
                    if addr!=self.peer:continue
                    try:m=decode(w,self.key)
                    except ValueError:self.rejected+=1;continue
                    if self.accept_probe(m):
                        try:sock.sendto(encode(self.packet('echo',m['seq']),self.key),self.peer)
                        except OSError as e:
                            self.error=str(e);sock.close();sock=None;break
                if sock is None:
                    stop.wait(.1);continue
                now=time.monotonic()
                if now>=due:
                    m=self.packet('data',self.seq)
                    m.update(generated_ns=time.monotonic_ns(),probe=self.probe,
                             base=self.seq-len(self.results),results=list(self.results),synthetic=True)
                    wire=encode(m,self.key)
                    reset_socket=False
                    try:ok=sock.sendto(wire,self.peer)==len(wire);self.error=None
                    except OSError as e:ok=False;self.error=str(e);reset_socket=True
                    self.results.append(ok);self.sent+=int(ok);self.local_failures+=int(not ok)
                    if journal:journal.write(json.dumps(dict(seq=self.seq,ok=ok,local_ns=time.monotonic_ns()))+'\n');journal.flush()
                    self.seq+=1
                    # A removed/re-added local address can invalidate a bound UDP
                    # socket. Keep identity/history, but bind a new socket on retry.
                    if reset_socket:sock.close();sock=None
                    # No catch-up bursts after OS suspend or adapter recovery.
                    due=next_send_deadline(due,now,self.period)
                stop.wait(.002)
        finally:
            if sock:sock.close()
            self.running=False
