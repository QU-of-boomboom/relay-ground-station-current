"""Serialize actual FPGA result fields, without recomputing quality decisions."""
CONDITIONS = ('UNAVAILABLE', 'BAD', 'BAND', 'GOOD')
REASONS = ('VALID', 'INVALID_INTERVAL', 'SOURCE_UNAVAILABLE', 'THRESHOLD_OVERLAP')


def alarm_record(client, slot, stop, *, clock_ns, deadline_ns):
    """Read PL after its default dwell; preserve the read as history, not authority.

    A bounded, interruptible 4ms wait allows the default 2ms dwell plus tick
    alignment. Longer configured dwell is returned as pending, never emulated.
    The receiver thread continues collecting packets during this wait.
    """
    if client.unified is None or stop.is_set():
        return None
    remaining = max(0, deadline_ns - clock_ns()) / 1e9
    if stop.wait(min(.004, remaining)) or stop.is_set():
        return None
    started = clock_ns()
    value = client.unified_snapshot(slot)
    completed = clock_ns()
    return dict(value=value, read_started_ns=started, read_completed_ns=completed,
                within_host_envelope=completed < deadline_ns,
                display_scope='hardware_sample_history_not_current_validity')


def quality_record(result):
    h = result.horizon
    return dict(source='FPGA_LINK_SERVICE', tag=h.tag, slot=h.slot,
        node=h.settings.node, session=h.settings.session,
        epoch=h.settings.epoch, revision=h.settings.revision,
        condition=CONDITIONS[result.condition], pdr=CONDITIONS[result.pdr],
        missing=[name for bit,name in enumerate(('PDR','RTT','AoI')) if result.missing & (1<<bit)],
        rtt=dict(condition=CONDITIONS[result.rtt_condition],reason=REASONS[result.rtt_reason],
                 lower_ns=h.rtt[0],upper_ns=h.rtt[1],available=h.rtt[4]),
        aoi=dict(condition=CONDITIONS[result.aoi_condition],reason=REASONS[result.aoi_reason],
                 lower_ns=h.aoi[0],upper_ns=h.aoi[1],available=h.aoi[4]),
        started_ns=h.started_ns,completed_ns=result.completed_ns,deadline_ns=h.deadline_ns,
        transaction_ns=result.completed_ns-h.started_ns,
        pl_time_ms=result.pl_time_ms,pl_generation=result.pl_generation,
        display_scope='last_evaluation_not_control_authority')
