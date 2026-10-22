"""Read existing worker JSONL only; never opens UIO or changes reception.

Usage on board: python3 print_board_quality.py /path/to/run/dashboard.jsonl
Ctrl-C stops this viewer only. The receiver has its own STOP lifecycle.
"""
import argparse
import json
from pathlib import Path
import time

def main():
    p=argparse.ArgumentParser()
    p.add_argument('log',type=Path)
    p.add_argument('--seconds',type=int,default=0)
    a=p.parse_args()
    if a.seconds<0:raise ValueError('seconds must be nonnegative')
    started=time.monotonic();latest={};last_print=0
    with a.log.open(encoding='utf8') as f:
        f.seek(0,2)
        try:
            while not a.seconds or time.monotonic()-started<a.seconds:
                position=f.tell();line=f.readline()
                if line and not line.endswith('\n'):
                    f.seek(position);line=''
                if line:
                    row=json.loads(line)
                    if row.get('kind')=='quality':
                        for item in row['nodes']:
                            latest[item['node']]=(item['value'],row['board_monotonic_ns'])
                    if row.get('kind')=='done':
                        print('RECEIVER_STOPPED',flush=True);return
                now=time.monotonic()
                if now-last_print>=1:
                    last_print=now
                    for node,(q,observed) in latest.items():
                        age=max(0,time.monotonic_ns()-observed)/1e9
                        sample=q.get('alarm_sample') or {};v=sample.get('value') or {}
                        alarm=v.get('state','UNAVAILABLE') if age<1 else 'STALE'
                        print(json.dumps(dict(node=node,age_s=round(age,3),
                            rtt=q['rtt'],aoi=q['aoi'],fpga_quality=q['condition'],
                            fpga_alarm_sample=alarm,hardware_valid_at_read=v.get('valid'),
                            scope='history_only_not_current_control_authority')),
                            flush=True)
                if not line:time.sleep(.05)
        except KeyboardInterrupt:pass

if __name__=='__main__':main()
