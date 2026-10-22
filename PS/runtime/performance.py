"""Bounded observational counters; nested durations must not be added together."""
from functools import wraps
import time


class Performance:
    def __init__(self):
        self.started=time.monotonic_ns();self.calls={};self.maxima={}

    def wrap(self,obj,method,label):
        original=getattr(obj,method)
        @wraps(original)
        def measured(*args,**kwargs):
            start=time.monotonic_ns()
            try:return original(*args,**kwargs)
            finally:
                elapsed=time.monotonic_ns()-start
                row=self.calls.setdefault(label,dict(count=0,total_ns=0,max_ns=0))
                row['count']+=1;row['total_ns']+=elapsed;row['max_ns']=max(row['max_ns'],elapsed)
        setattr(obj,method,measured)

    def maximum(self,name,value):
        self.maxima[name]=max(self.maxima.get(name,0),value)

    def report(self):
        return dict(elapsed_ns=time.monotonic_ns()-self.started,calls=self.calls,maxima=self.maxima,
                    note='nested instrumented timings; not additive; includes instrumentation overhead')
