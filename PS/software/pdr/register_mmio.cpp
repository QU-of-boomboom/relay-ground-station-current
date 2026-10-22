// Ordered 32-bit UIO register helper. File mode is explicitly a host test backend.
#include <atomic>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "uio_identity.hpp"

namespace {
constexpr std::size_t aperture = 4096;

void device_barrier() {
#if defined(__arm__) || defined(__aarch64__)
    // Full-system barrier is deliberate: the UIO map contains device registers.
    __asm__ __volatile__("dmb sy" ::: "memory");
#else
    std::atomic_thread_fence(std::memory_order_seq_cst);
#endif
}

#ifndef GS_MMIO_LIBRARY
std::uint64_t number(const std::string& text) {
    if (text.empty() || text.size() > 18 || text[0] == '-') throw std::runtime_error("invalid number");
    std::size_t used = 0;
    const auto value = std::stoull(text, &used, 0);
    if (used != text.size()) throw std::runtime_error("trailing numeric characters");
    return value;
}

bool line(std::string& output) {
    output.clear();
    char ch;
    while (std::cin.get(ch)) {
        if (ch == '\n') return true;
        if (output.size() >= 96) throw std::runtime_error("command line too long");
        if (ch == '\r' || ch == '\0') throw std::runtime_error("invalid command byte");
        output.push_back(ch);
    }
    if (!output.empty()) throw std::runtime_error("truncated command");
    return false;
}

#endif
class Mapping {
public:
    explicit Mapping(const std::string& mode, const std::string& path) {
        const std::uint16_t endian = 1;
        if (*reinterpret_cast<const std::uint8_t*>(&endian) != 1) throw std::runtime_error("little endian required");
        std::string sys;
        station_uio::Identity before {};
        if (mode == "--uio") {
            sys = "/sys/class/uio/" + station_uio::device_name(path);
            before = station_uio::read_identity(sys);
        } else if (mode != "--file") throw std::runtime_error("backend mode required");
        fd_ = open(path.c_str(), O_RDWR | O_SYNC | O_CLOEXEC | O_NOFOLLOW);
        if (fd_ < 0) throw std::runtime_error("cannot open register mapping");
        try {
            struct stat info {};
            if (fstat(fd_, &info) != 0) throw std::runtime_error("mapping stat failed");
            if (mode == "--file" && (!S_ISREG(info.st_mode) || info.st_size < static_cast<off_t>(aperture)))
                throw std::runtime_error("test mapping must be a full regular file");
            if (mode == "--uio" && !S_ISCHR(info.st_mode)) throw std::runtime_error("UIO must be a character device");
            if (flock(fd_, LOCK_EX | LOCK_NB) != 0) throw std::runtime_error("mapping already owned");
            if (mode == "--uio")
                station_uio::validate_opened(before, station_uio::read_identity(sys), info);
            memory_ = mmap(nullptr, aperture, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
            if (memory_ == MAP_FAILED) throw std::runtime_error("mmap failed");
        } catch (...) { close(fd_); fd_ = -1; throw; }
    }
    ~Mapping() {
        if (memory_ != MAP_FAILED) munmap(memory_, aperture);
        if (fd_ >= 0) close(fd_);
    }
    Mapping(const Mapping&) = delete;
    Mapping& operator=(const Mapping&) = delete;
    std::uint32_t read(std::uint64_t offset) {
        auto* word = at(offset);
        device_barrier();
        const std::uint32_t value = *word;
        device_barrier();
        return value;
    }
    void write(std::uint64_t offset, std::uint64_t value) {
        auto* word = at(offset);
        if (value > std::numeric_limits<std::uint32_t>::max()) throw std::runtime_error("write value exceeds word");
        device_barrier();
        *word = static_cast<std::uint32_t>(value);
        device_barrier();
    }
private:
    volatile std::uint32_t* at(std::uint64_t offset) {
        if (offset > aperture - 4 || offset % 4 != 0) throw std::runtime_error("unaligned or out of range");
        return reinterpret_cast<volatile std::uint32_t*>(static_cast<std::uint8_t*>(memory_) + offset);
    }
    int fd_ = -1;
    void* memory_ = MAP_FAILED;
};
}

#ifndef GS_MMIO_LIBRARY
int main(int argc, char** argv) {
    try {
        if (argc != 3) throw std::runtime_error("usage: register_mmio --uio /dev/uioN | --file test.bin");
        Mapping mapping(argv[1], argv[2]);
        std::cout << "READY 2 " << (std::string(argv[1]) == "--uio" ? "UIO" : "FILE") << '\n' << std::flush;
        std::string request;
        while (line(request)) {
            std::istringstream fields(request);
            std::string operation, address, value, extra;
            fields >> operation;
            if (operation == "CLOSE") {
                if (fields >> extra) throw std::runtime_error("extra close fields");
                std::cout << "CLOSED\n" << std::flush;
                return 0;
            }
            if (operation == "READS") {
                if (!(fields >> value)) throw std::runtime_error("missing read count");
                const auto count = number(value);
                if (count < 1 || count > 8) throw std::runtime_error("read count range");
                std::array<std::uint64_t, 8> addresses {};
                std::array<std::uint32_t, 8> results {};
                // Validate the complete request before touching any register.
                for (std::size_t i = 0; i < count; ++i) {
                    if (!(fields >> address)) throw std::runtime_error("missing batch address");
                    addresses[i] = number(address);
                    if (addresses[i] > aperture - 4 || addresses[i] % 4 != 0)
                        throw std::runtime_error("batch address range");
                }
                if (fields >> extra) throw std::runtime_error("extra batch fields");
                // Each read retains its barriers; duplicates are actual reads.
                for (std::size_t i = 0; i < count; ++i) results[i] = mapping.read(addresses[i]);
                std::cout << "VALUES " << std::dec << count;
                for (std::size_t i = 0; i < count; ++i) std::cout << ' ' << results[i];
                std::cout << '\n' << std::flush;
                continue;
            }
            if (!(fields >> address)) throw std::runtime_error("missing address");
            if (operation == "READ") {
                if (fields >> extra) throw std::runtime_error("extra read fields");
                const auto result = mapping.read(number(address));
                std::cout << "VALUE " << std::dec << result << '\n' << std::flush;
            } else if (operation == "WRITE") {
                if (!(fields >> value) || fields >> extra) throw std::runtime_error("write fields");
                mapping.write(number(address), number(value));
                std::cout << "WRITTEN\n" << std::flush;
            } else throw std::runtime_error("unknown operation");
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "register backend stopped: " << error.what() << '\n';
        return 1;
    }
}
#endif
