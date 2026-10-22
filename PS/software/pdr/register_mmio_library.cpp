// Reuse the exact mapping/identity/flock/barrier implementation of the helper.
#define GS_MMIO_LIBRARY
#include "register_mmio.cpp"
#include "native_slot_guard.hpp"
#include "event_batch.hpp"
#include <chrono>

namespace {
thread_local std::string last_error;
template<class F> int checked(F operation) noexcept {
    try { operation(); last_error.clear(); return 0; }
    catch (const std::exception& e) { last_error = e.what(); return -1; }
    catch (...) { last_error = "unknown native MMIO error"; return -1; }
}
}
extern "C" {
unsigned gs_mmio_abi() { return 1; }
unsigned gs_mmio_guarded_abi() { return 1; }
unsigned gs_mmio_event_batch_abi() { return 1; }
const char* gs_mmio_error() { return last_error.c_str(); }
int gs_mmio_open(const char* mode, const char* path, void** result) noexcept {
    return checked([&] {
        if (!mode || !path || !result) throw std::runtime_error("null open argument");
        *result = new Mapping(mode, path);
    });
}
int gs_mmio_read(void* handle, std::uint64_t offset, std::uint32_t* result) noexcept {
    return checked([&] {
        if (!handle || !result) throw std::runtime_error("null read argument");
        *result = static_cast<Mapping*>(handle)->read(offset);
    });
}
int gs_mmio_write(void* handle, std::uint64_t offset, std::uint64_t value) noexcept {
    return checked([&] {
        if (!handle) throw std::runtime_error("null write argument");
        static_cast<Mapping*>(handle)->write(offset, value);
    });
}
void gs_mmio_close(void* handle) noexcept { delete static_cast<Mapping*>(handle); }
int gs_mmio_slot_epoch(void* handle,unsigned slot,std::uint64_t token,std::uint32_t* result) noexcept {
    return checked([&] {
        if(!handle || !result)throw std::runtime_error("null epoch arguments");
        auto value=station_native::epoch(*static_cast<Mapping*>(handle),slot,token);
        result[0]=value.first;result[1]=value.second;
    });
}
int gs_mmio_slot_transfer(void* handle,unsigned slot,std::uint64_t token,std::uint32_t outer,
                         std::uint32_t local,unsigned write,const std::uint32_t* offsets,
                         std::uint32_t* values,unsigned count) noexcept {
    return checked([&] {
        if(!handle)throw std::runtime_error("null transfer handle");
        station_native::transfer(*static_cast<Mapping*>(handle),slot,token,outer,local,write,offsets,values,count);
    });
}
int gs_mmio_event_batch(void* handle,unsigned slot,std::uint64_t token,std::uint32_t outer,
                       std::uint32_t local,const std::uint32_t* words,unsigned count,
                       std::uint64_t budget_ns,std::uint32_t* receipt) noexcept {
    if(receipt) {receipt[0]=0;receipt[1]=0;receipt[2]=0;}
    station_native::EventBatchResult result;
    const int rc=checked([&] {
        if(!handle || !receipt || !words || slot>3 || !budget_ns || budget_ns>50000000)
            throw std::runtime_error("invalid event batch arguments/budget");
        struct GuardedBank {
            Mapping& map;unsigned slot;std::uint64_t token;std::uint32_t outer,local;
            std::uint32_t read(std::uint32_t offset) {
                std::uint32_t address=0x240+offset,value=0;
                station_native::transfer(map,slot,token,outer,local,0,&address,&value,1);
                return value;
            }
            void write(std::uint32_t offset,std::uint32_t value) {
                std::uint32_t address=0x240+offset;
                station_native::transfer(map,slot,token,outer,local,1,&address,&value,1);
            }
        } io{*static_cast<Mapping*>(handle),slot,token,outer,local};
        auto now=[] {return std::uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());};
        station_native::event_batch(io,now,now()+budget_ns,words,count,result);
    });
    if(receipt) {receipt[0]=result.accepted_prefix;receipt[1]=result.bank_status;receipt[2]=result.completion_unknown;}
    return rc;
}
}
