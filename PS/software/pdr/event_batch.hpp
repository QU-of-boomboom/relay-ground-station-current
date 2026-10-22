// Bounded batch submission; IO retains the existing per-word hardware guards.
#pragma once
#include <cstdint>
#include <stdexcept>

namespace station_native {
struct EventBatchResult {
    std::uint32_t accepted_prefix=0;
    std::uint32_t bank_status=0;
    bool completion_unknown=false;
};

template<class IO> std::uint64_t event_counter(IO& io,unsigned low) {
    for(unsigned attempt=0;attempt<3;++attempt) {
        const auto high=io.read(low+4);
        const auto value=io.read(low);
        if(io.read(low+4)==high)return value|(std::uint64_t(high)<<32);
    }
    throw std::runtime_error("event counter unstable");
}

// Caller owns the transport and supplies a monotonic absolute deadline.
// On exception, result keeps the confirmed prefix and unknown-completion flag.
template<class IO, class Clock> void event_batch(IO& io,Clock now,std::uint64_t deadline,
        const std::uint32_t* words,unsigned count,EventBatchResult& result) {
    result=EventBatchResult{};
    if(!words || count<1 || count>16)throw std::runtime_error("batch count 1..16 required");
    auto check=[&] {if(now()>=deadline)throw std::runtime_error("event batch deadline");};
    check();
    if(io.read(0)!=0x47534531 || io.read(4)!=0x10001 || io.read(0x2c)!=0x00200020)
        throw std::runtime_error("event bank identity/ABI/capacity mismatch");
    for(unsigned n=0;n<count;++n) {
        check();
        const auto record=words+n*32;
        const auto ordinal=record[10]|(std::uint64_t(record[11])<<32);
        const auto status=io.read(8);
        if(status==1 || status==2)throw std::runtime_error("event bank busy; no blind retry");
        if(ordinal==UINT64_MAX || event_counter(io,0x10)!=ordinal)
            throw std::runtime_error("event ordinal does not match accepted cursor");
        // Discard only an uncommitted shadow, never an accepted event.
        io.write(0x28,0x41425254);
        for(unsigned w=0;w<32;++w) {check();io.write(0x40+w*4,record[w]);}
        check();
        result.completion_unknown=true; // Set BEFORE the write may throw.
        io.write(0x24,0x434d4954);
        for(;;) {
            check();
            const auto value=io.read(8);result.bank_status=value;
            if(value==1 || value==2)continue;
            const auto accepted=event_counter(io,0x10);
            if(value==3 && accepted==ordinal+1) {
                ++result.accepted_prefix;result.completion_unknown=false;break;
            }
            if((value==4 || value==5 || value==6 || value==7 || value==8 || value==10 || value==11) && accepted==ordinal) {
                result.completion_unknown=false;
                return; // Explicit rejection: caller decides, no automatic retry.
            }
            throw std::runtime_error("event receipt/reset ambiguous; do not retry");
        }
    }
}
}
