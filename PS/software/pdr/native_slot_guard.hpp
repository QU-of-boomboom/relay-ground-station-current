// Exact PhysicalSlotTransport guard order, executed without Python callbacks.
#pragma once
#include <cstdint>
#include <stdexcept>
#include <utility>
namespace station_native {
template<class IO> void lease(IO& io,std::uint64_t token) {
    auto low=io.read(0xfc8);auto high=io.read(0xfcc);
    auto again=io.read(0xfc8);auto error=io.read(0xfd4);
    if(low!=again || (low|(std::uint64_t(high)<<32))!=token || error)
        throw std::runtime_error("PS reset or software owner changed");
}
template<class IO> std::uint32_t outer(IO& io,std::uint64_t token) {
    lease(io,token);
    auto id=io.read(0xf00);auto abi=io.read(0xf0c);auto before=io.read(0xf08);
    auto status=io.read(0xf04);auto after=io.read(0xf08);
    if(id!=0x47535431 || abi!=0x10001 || before!=after || (status&~7u) || (status&3)!=3)
        throw std::runtime_error("physical backend identity/reset/sticky fault");
    lease(io,token);return before;
}
template<class IO> std::pair<std::uint32_t,std::uint32_t> epoch(IO& io,unsigned slot,std::uint64_t token) {
    if(slot>3)throw std::runtime_error("slot range");
    auto before=outer(io,token);auto base=slot*0x400;
    // Preserve the reference's short-circuit identity rejection.
    if(io.read(base+0x200)!=0x47535431 || io.read(base+0x20c)!=0x10001)
        throw std::runtime_error("slot guard identity/ABI");
    auto local=io.read(base+0x208);auto status=io.read(base+0x204);auto after=io.read(base+0x208);
    if(local!=after || (status&~7u) || (status&3)!=3)throw std::runtime_error("slot reset/sticky fault");
    if(outer(io,token)!=before)throw std::runtime_error("outer reset while reading slot guard");
    return {before,local};
}
template<class IO> void transfer(IO& io,unsigned slot,std::uint64_t token,std::uint32_t outer_epoch,
                                std::uint32_t local_epoch,unsigned write,const std::uint32_t* offsets,
                                std::uint32_t* values,unsigned count) {
    if(slot>3 || write>1 || !offsets || !values || count<1 || count>32)
        throw std::runtime_error("guarded transfer arguments");
    for(unsigned i=0;i<count;++i)
        if(offsets[i]>=0x400 || offsets[i]%4 || (slot==3 && offsets[i]>=0x300))
            throw std::runtime_error("guarded slot offset");
    const auto expected=std::make_pair(outer_epoch,local_epoch);
    for(unsigned i=0;i<count;++i) {
        if(epoch(io,slot,token)!=expected)throw std::runtime_error("reset during guarded command");
        if(write)io.write(slot*0x400+offsets[i],values[i]);
        else values[i]=io.read(slot*0x400+offsets[i]);
        if(epoch(io,slot,token)!=expected)throw std::runtime_error("reset during guarded command");
    }
}
}
