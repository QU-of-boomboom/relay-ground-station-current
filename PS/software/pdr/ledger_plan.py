"""Offline closed-ledger planner. Emits data only; never opens a device."""
import argparse
import json
from pathlib import Path
from reference import PacketId, settle_batch
from transaction_reference import Request


def exact_keys(value, keys):
    if type(value) is not dict or set(value) != set(keys.split()):
        raise ValueError("unexpected or missing ledger fields")


def plan(batch):
    exact_keys(batch, "schema closed tx_complete rx_complete epoch node session sent received")
    if type(batch["schema"]) is not int or batch["schema"] != 1:
        raise ValueError("unsupported schema")
    if any(batch[k] is not True for k in ("closed", "tx_complete", "rx_complete")):
        raise ValueError("explicit closure and complete ledgers required")
    epoch, node, session = (batch[k] for k in ("epoch", "node", "session"))
    PacketId(node, session, 0)
    if type(epoch) is not int or not 1 <= epoch < 2**64:
        raise ValueError("explicit nonzero epoch required")
    if any(type(batch[k]) is not list for k in ("sent", "received")):
        raise ValueError("ledger arrays required")
    sent, received = [], []
    failed = 0
    for row in batch["sent"]:
        exact_keys(row, "sequence send_ok")
        key = PacketId(node, session, row["sequence"])
        if type(row["send_ok"]) is not bool:
            raise ValueError("send_ok must be boolean")
        if row["send_ok"]:
            sent.append(key)
        else:
            failed += 1
    for row in batch["received"]:
        exact_keys(row, "node session sequence")
        received.append(PacketId(**row))
    outcomes = settle_batch(sent, received, closed=True)
    if len(outcomes) > 0xffffffff:
        raise ValueError("outcome index exhausted")
    requests = [Request(1, 0, epoch, node, session)]
    requests += [Request(2, (i+1) & 65535, epoch, node, session, i, int(ok))
                 for i, ok in enumerate(outcomes)]
    requests.append(Request(3, (len(outcomes)+1) & 65535, epoch, node, session))
    words = [[(r.pack() >> (32*i)) & 0xffffffff for i in range(8)] for r in requests]
    matched = set(sent) & set(received)
    return dict(schema=1, offline_only=True, epoch=epoch, node=node, session=session,
                successful_sends=len(sent), local_send_failures=failed,
                delivered=len(matched), lost=len(sent)-len(matched),
                duplicate_receives=len(received)-len(set(received)),
                unmatched_unique_receives=len(set(received)-set(sent)),
                pdr=(len(matched)/len(sent) if sent else None),
                outcomes=[dict(index=i, sequence=k.sequence, received=ok)
                          for i, (k, ok) in enumerate(zip(sent, outcomes))],
                commands=words)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ledger", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = plan(json.loads(args.ledger.read_text(encoding="utf-8-sig"),
                             object_pairs_hook=unique_object))
    # Exclusive create protects evidence from accidental replacement.
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print("PASS offline plan; no FPGA access")
