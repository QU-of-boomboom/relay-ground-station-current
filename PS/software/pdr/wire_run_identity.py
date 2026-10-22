"""Persistent tombstones prevent accidental reuse of authenticated wire contexts.

The root must survive endpoint restarts. A new output/log directory is not a new
wire identity, and deleting the registry is outside this guarantee.
"""
from dataclasses import dataclass,field
import json
import os
from pathlib import Path
import threading

from remote_round_protocol import Context
from durable_directory import ensure_directory,sync_directory


@dataclass
class WireRunClaim:
    role:str
    node:int
    session:int
    nonce:bytes
    marker:Path
    owner:int=field(default_factory=threading.get_ident,repr=False)
    consumed:bool=field(default=False,repr=False)

    def consume(self,role,node,session,nonce):
        if threading.get_ident()!=self.owner or self.consumed:raise ValueError('fresh owner wire claim required')
        if (role,node,session,nonce)!=(self.role,self.node,self.session,self.nonce):raise ValueError('wire claim binding changed')
        expected=dict(schema=1,role=role,node=node,session=session,nonce=nonce.hex())
        with self.marker.open('rb') as stream:raw=stream.read(513)
        if len(raw)>512 or json.loads(raw)!=expected:raise ValueError('wire identity marker changed')
        self.consumed=True


def reserve(root,*,role,node,session,nonce):
    if role not in ('host','drone'):raise ValueError('explicit wire role')
    Context(node,session,1,nonce,0,1)
    root=ensure_directory(root)
    marker=root/f'{role}_{node}_{session}_{nonce.hex()}.json'
    row=dict(schema=1,role=role,node=node,session=session,nonce=nonce.hex())
    # Exclusive creation is the process-race guard. Never remove on close/failure.
    with marker.open('xb') as stream:
        stream.write((json.dumps(row,sort_keys=True,separators=(',',':'))+'\n').encode('ascii'))
        stream.flush();os.fsync(stream.fileno())
    sync_directory(root)
    return WireRunClaim(role,node,session,nonce,marker)
