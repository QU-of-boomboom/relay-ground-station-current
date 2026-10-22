"""Reception completeness with authenticated cumulative send evidence.

Subclass reuses ContinuousStation/PL command and quality guards. It deliberately
does not reinterpret sender monotonic timestamps as board timestamps.
"""
from collections import deque
from online_settlement import OnlineSettlement, Outcome


class PushSettlement(OnlineSettlement):
    mode='authenticated_push_reception'

    def __init__(self,qualification_window=64,**kwargs):
        super().__init__(**kwargs)
        self.deadline_origin='first_local_send_evidence'
        self.cursor=None;self.received={};self.facts={};self.fact_times={}
        self.highest_data=-1;self.last_packet=None;self.omitted=0;self.conflicts=0
        self.history_floor=0;self.qualify_after=0;self.qualification_window=qualification_window

    def _skip_unknown(self):
        if self.cursor is not None and self.cursor<self.history_floor and self.cursor not in self.facts:
            end=min((n for n in self.facts if n>self.cursor),default=self.history_floor)
            end=min(end,self.history_floor)
            self.omitted+=end-self.cursor;self.cursor=end
            self.qualify_after=self.next_index+self.qualification_window

    def ingest(self,m,observed_ns,now_ns):
        self._time(now_ns)
        if observed_ns<self.started or observed_ns>now_ns:raise ValueError('receive observation outside run')
        seq=m['seq']
        if self.cursor is None:
            # Start at first current-challenge DATA; stopped intervals are excluded.
            self.cursor=seq
        if seq<self.cursor or seq in self.received:self.duplicates+=1;return False
        if seq>self.highest_data:
            self.highest_data=seq;self.last_packet=observed_ns
        self.received[seq]=observed_ns
        reports=list(enumerate(m['results'],m['base']))+[(seq,True)]
        self.history_floor=max(self.history_floor,m['base'])
        for n,ok in reports:
            if n<self.cursor:continue
            if (n in self.facts and self.facts[n]!=ok) or (not ok and n in self.received):
                self.conflicts+=1;self.fault('authenticated contradictory send history')
            if n not in self.facts:self.facts[n]=ok;self.fact_times[n]=observed_ns
        # Never discard already received/known but not yet settled evidence.
        self._skip_unknown()
        for store in (self.received,self.facts,self.fact_times):
            for n in list(store):
                if n<self.cursor:del store[n]
        if len(self.facts)>self.capacity or len(self.received)>self.capacity:
            self.fault('push evidence capacity exceeded')
        return True

    def advance(self,tx_watermark_ns,rx_watermark_ns,now_ns,*,max_outcomes=None):
        self._time(now_ns)
        if not self.tx_watermark<=tx_watermark_ns<=now_ns or not self.rx_watermark<=rx_watermark_ns<=now_ns:
            self.fault('push watermark regression')
        self.tx_watermark,self.rx_watermark=tx_watermark_ns,rx_watermark_ns
        outcomes=[]
        while len(outcomes)<(max_outcomes or self.capacity):
            self._skip_unknown()
            if self.cursor is None or self.cursor not in self.facts:break
            n=self.cursor;t=self.fact_times[n];deadline=t+self.budget
            if deadline>min(tx_watermark_ns,rx_watermark_ns):break
            ok=self.facts.pop(n);del self.fact_times[n]
            observed=self.received.pop(n,None);self.cursor+=1;self.highest=n
            if not ok:self.failed+=1;continue
            if self.next_index>=0xffffffff:self.fault('PL outcome index exhausted')
            delivered=observed is not None and observed<=deadline
            outcomes.append(Outcome(self.next_index,n,t,deadline,delivered))
            self.next_index+=1;self.sent+=1;self.delivered+=int(delivered);self.last_closed=deadline
        return tuple(outcomes)

    def status(self,now_ns):
        s=super().status(now_ns)
        s.update(mode=self.mode,unknown_omitted=self.omitted,pending=len(self.facts),
                 received_packets=len(self.received),last_packet_ns=self.last_packet)
        s['realtime_eligible'] &= self.last_packet is not None and now_ns-self.last_packet<self.timeout
        # Do not qualify stale or unprocessed send evidence as a fresh full window.
        backlog=any(t+self.budget<=now_ns for t in self.fact_times.values())
        s['settlement_backlog']=backlog;s['realtime_eligible'] &= not backlog
        s['unknown_window_rebuilding']=self.next_index<self.qualify_after
        s['realtime_eligible'] &= not s['unknown_window_rebuilding']
        return s
