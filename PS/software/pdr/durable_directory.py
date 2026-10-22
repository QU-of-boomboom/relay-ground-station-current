"""POSIX directory-entry durability before persistent identities become usable.

Windows has no portable Python directory fsync here; process restart exclusion
is tested there, while power-loss durability still depends on the filesystem.
"""
import os
from pathlib import Path


def sync_directory(directory):
    if os.name == 'posix':
        descriptor=os.open(directory,os.O_RDONLY | getattr(os,'O_DIRECTORY',0))
        try:os.fsync(descriptor)
        finally:os.close(descriptor)


def ensure_directory(path):
    root=Path(path).resolve()
    missing=[]
    cursor=root
    while not cursor.exists():
        missing.append(cursor)
        cursor=cursor.parent
    if not cursor.is_dir():raise NotADirectoryError(str(cursor))
    for directory in reversed(missing):
        directory.mkdir(exist_ok=True)
        sync_directory(directory.parent)
    return root
