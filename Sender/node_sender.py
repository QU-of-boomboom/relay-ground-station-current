"""Standalone PC/Linux autonomous test node; no dashboard connection required."""
import argparse
import signal
import sys
import threading
from push_protocol import AutonomousSender


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--node',type=int,required=True)
    p.add_argument('--session',type=int,required=True,help='unique transmitter lifetime; must match receiver provisioning')
    p.add_argument('--bind-ip',required=True);p.add_argument('--bind-port',type=int,required=True)
    p.add_argument('--board-ip',required=True);p.add_argument('--board-port',type=int,required=True)
    p.add_argument('--period-ms',type=int,default=100)
    a=p.parse_args();key=bytes.fromhex(sys.stdin.readline().strip())
    if len(key)!=32:raise ValueError('provide 32-byte hex key on stdin; never command line')
    stop=threading.Event()
    for sig in (signal.SIGINT,signal.SIGTERM):signal.signal(sig,lambda *_:stop.set())
    sender=AutonomousSender(a.node,a.session,key,(a.bind_ip,a.bind_port),(a.board_ip,a.board_port),a.period_ms/1000)
    sender.run(stop)


if __name__=='__main__':main()
