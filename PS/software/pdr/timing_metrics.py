"""Correlated RTT and explicit-clock-domain AoI; no remote clock guessing."""
from collections import deque
from dataclasses import dataclass
from quality_reference import integer
from reference import PacketId


class TimingFault(RuntimeError):pass


@dataclass(frozen=True)
class GenerationBounds:
    lower_ns: int
    upper_ns: int
    clock_domain: str

    def __post_init__(self):
        integer(self.lower_ns,0,2**63-1)
        integer(self.upper_ns,self.lower_ns,2**63-1)
        if type(self.clock_domain) is not str or not self.clock_domain:
            raise ValueError('explicit local clock domain required')


def classify_interval(lower,upper,good,bad):
    if upper<=good:return 'GOOD'
    if lower>=bad:return 'BAD'
    if lower>good and upper<bad:return 'BAND'
    return 'UNCERTAIN'


class TimingMetrics:
    def __init__(self,*,node,session,clock_domain,started_ns,probe_timeout_ns,
                 max_sample_age_ns,rtt_good_ns,rtt_bad_ns,aoi_good_ns,aoi_bad_ns,
                 capacity=256,window=64):
        PacketId(node,session,0)
        integer(started_ns,0,2**63-1);integer(probe_timeout_ns,1,2**63-1)
        integer(max_sample_age_ns,1,2**63-1);integer(capacity,1,4096);integer(window,1,256)
        for good,bad in ((rtt_good_ns,rtt_bad_ns),(aoi_good_ns,aoi_bad_ns)):
            integer(good,0,2**63-2);integer(bad,good+1,2**63-1)
        if type(clock_domain) is not str or not clock_domain:raise ValueError('clock domain')
        self.node,self.session,self.domain=node,session,clock_domain
        self.now=started_ns;self.started=started_ns;self.timeout=probe_timeout_ns
        self.max_age=max_sample_age_ns;self.capacity=capacity
        self.rtt_good,self.rtt_bad=rtt_good_ns,rtt_bad_ns
        self.aoi_good,self.aoi_bad=aoi_good_ns,aoi_bad_ns
        self.pending={};self.samples=deque(maxlen=window);self.highest_probe=-1
        self.highest_state=-1;self.generation=None;self.state_received=None;self.aoi_reason='NO_DATA'
        self.timeouts=self.send_failures=self.unmatched=self.foreign=0
        self.last_reply=None;self.stopped=None

    def stop(self,reason):
        if type(reason) is not str or not reason:raise ValueError('explicit stop reason required')
        if self.stopped is None:self.stopped=reason

    def _fault(self,reason):
        self.stop(reason);raise TimingFault(reason)

    def _time(self,now):
        if self.stopped:raise TimingFault('timing run stopped')
        try:integer(now,self.now,2**63-1)
        except ValueError:self._fault('local clock invalid/regressed')
        self.now=now

    def _expire(self,now):
        expired=[seq for seq,sent in self.pending.items() if now-sent>self.timeout]
        for seq in expired:del self.pending[seq]
        self.timeouts+=len(expired)

    def _identity(self,node,session,sequence):
        try:PacketId(node,session,sequence)
        except ValueError:self._fault('invalid identity')
        if (node,session)!=(self.node,self.session):
            self.foreign+=1;return False
        return True

    def probe_sent(self,sequence,send_ok,now_ns,*,observed_ns=None):
        self._time(now_ns);self._expire(now_ns)
        observed=now_ns if observed_ns is None else observed_ns
        try:integer(observed,self.started,now_ns)
        except ValueError:self._fault('invalid probe send observation')
        self._identity(self.node,self.session,sequence)
        if type(send_ok) is not bool or sequence<=self.highest_probe:
            self._fault('probe sequence/result invalid')
        if send_ok and (len(self.pending)>=self.capacity or now_ns>2**63-1-self.timeout):
            self._fault('probe capacity/time space exceeded')
        self.highest_probe=sequence
        if send_ok:self.pending[sequence]=observed
        else:self.send_failures+=1

    def reply(self,node,session,sequence,received_ns,now_ns):
        self._time(now_ns)
        try:integer(received_ns,self.started,now_ns)
        except ValueError:self._fault('invalid local response time')
        if not self._identity(node,session,sequence):return 'FOREIGN'
        sent=self.pending.get(sequence)
        if sent is None:self.unmatched+=1;return 'UNMATCHED'
        if received_ns<sent:self._fault('response precedes send')
        del self.pending[sequence]
        if received_ns-sent>self.timeout:
            self.timeouts+=1;return 'TIMEOUT'
        # A delayed application callback may report an old but correct RTT.
        # Preserve the observation time; status uses it for qualification.
        self.samples.append((received_ns-sent,received_ns))
        self.last_reply=max(received_ns,self.last_reply if self.last_reply is not None else received_ns)
        return 'ACCEPTED'

    def state(self,node,session,sequence,generation,received_ns,now_ns):
        self._time(now_ns)
        try:integer(received_ns,self.started,now_ns)
        except ValueError:self._fault('invalid state observation time')
        if not self._identity(node,session,sequence):return 'FOREIGN'
        if sequence<=self.highest_state:return 'DUPLICATE_OR_OLD'
        previous=self.generation
        self.highest_state=sequence;self.state_received=received_ns;self.generation=None
        if generation is None or not isinstance(generation,GenerationBounds) or generation.clock_domain!=self.domain:
            self.aoi_reason='TIME_UNKNOWN';return self.aoi_reason
        if generation.upper_ns>received_ns:
            self.aoi_reason='TIME_INVALID';return self.aoi_reason
        if previous and (generation.lower_ns<previous.lower_ns or generation.upper_ns<previous.upper_ns):
            self.aoi_reason='TIME_REGRESSED';return self.aoi_reason
        self.generation=generation;self.aoi_reason='KNOWN';return 'ACCEPTED'

    def status(self,now_ns):
        if self.stopped:
            integer(now_ns,self.now,2**63-1)
            return dict(active=False,reason=self.stopped,rtt=dict(available=False,condition='STOPPED'),
                        aoi=dict(available=False,condition='STOPPED'))
        self._time(now_ns);self._expire(now_ns)
        # Expire individual samples as well as the newest arrival: stale high
        # values cannot remain in a newly refreshed rolling summary forever.
        fresh=[v for v,t in self.samples if now_ns-t<self.max_age]
        if not fresh:
            rtt=dict(available=False,condition='NO_DATA' if self.last_reply is None else 'STALE',count=0)
        else:
            low,high=min(fresh),max(fresh)
            rtt=dict(available=True,condition=classify_interval(high,high,self.rtt_good,self.rtt_bad),
                     count=len(fresh),min_ns=low,max_ns=high,mean_ns=sum(fresh)//len(fresh),
                     newest_age_ns=now_ns-self.last_reply)
        if self.generation is None:
            aoi=dict(available=False,condition=self.aoi_reason)
        else:
            low,high=now_ns-self.generation.upper_ns,now_ns-self.generation.lower_ns
            stale=now_ns-self.state_received>=self.max_age
            condition='STALE' if stale else classify_interval(low,high,self.aoi_good,self.aoi_bad)
            aoi=dict(available=not stale and condition!='UNCERTAIN',condition=condition,
                     lower_ns=low,upper_ns=high,sequence=self.highest_state,
                     receive_age_ns=now_ns-self.state_received)
        return dict(active=True,rtt=rtt,aoi=aoi,pending=len(self.pending),timeouts=self.timeouts,
                    local_send_failures=self.send_failures,unmatched=self.unmatched,foreign=self.foreign,
                    board_verified=False)
