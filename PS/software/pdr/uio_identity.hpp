// Read-only UIO metadata validation; production callers use the fixed sysfs root.
#pragma once
#include <cstdint>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/sysmacros.h>

namespace station_uio {
struct Identity {
    std::uint64_t major_number, minor_number, address, size, offset;
    bool operator==(const Identity& other) const {
        return major_number == other.major_number && minor_number == other.minor_number &&
               address == other.address && size == other.size && offset == other.offset;
    }
};

inline std::string device_name(const std::string& path) {
    if (path.rfind("/dev/uio", 0) != 0 || path.size() < 9 || path.size() > 12 ||
        path.find_first_not_of("0123456789", 8) != std::string::npos ||
        (path.size() > 9 && path[8] == '0'))
        throw std::runtime_error("canonical /dev/uioN required");
    return path.substr(5);
}

inline std::string attribute(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("UIO metadata unavailable");
    char bytes[65];
    file.read(bytes, sizeof(bytes));
    const auto count = file.gcount();
    if (file.bad() || count == 0 || count > 64)
        throw std::runtime_error("UIO metadata length or read error");
    std::string value(bytes, static_cast<std::size_t>(count));
    // sysfs emits one newline. Accept ASCII whitespace at the edges only.
    const auto first = value.find_first_not_of(" \t\r\n");
    const auto last = value.find_last_not_of(" \t\r\n");
    if (first == std::string::npos) throw std::runtime_error("empty UIO metadata");
    return value.substr(first, last - first + 1);
}

inline std::uint64_t integer(const std::string& text, bool hex_allowed) {
    std::size_t start = 0;
    unsigned base = 10;
    if (hex_allowed && text.rfind("0x", 0) == 0) { start = 2; base = 16; }
    if (text.size() == start) throw std::runtime_error("empty UIO number");
    std::uint64_t value = 0;
    for (std::size_t i = start; i < text.size(); ++i) {
        const auto c = text[i];
        const unsigned digit = c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
        if (digit >= base || value > (std::numeric_limits<std::uint64_t>::max() - digit) / base)
            throw std::runtime_error("invalid or overflowing UIO number");
        value = value * base + digit;
    }
    return value;
}

inline Identity read_identity(const std::string& directory) {
    const auto dev = attribute(directory + "/dev");
    const auto split = dev.find(':');
    if (split == std::string::npos) throw std::runtime_error("UIO device number missing");
    Identity result {integer(dev.substr(0, split), false), integer(dev.substr(split + 1), false),
        integer(attribute(directory + "/maps/map0/addr"), true),
        integer(attribute(directory + "/maps/map0/size"), true),
        integer(attribute(directory + "/maps/map0/offset"), true)};
    if (result.address != 0x400c1000 || result.size < 4096 || result.offset != 0)
        throw std::runtime_error("UIO map does not match station aperture");
    return result;
}

inline void validate_opened(const Identity& before, const Identity& after, const struct stat& info) {
    if (!S_ISCHR(info.st_mode) || !(before == after) ||
        after.major_number != static_cast<std::uint64_t>(major(info.st_rdev)) ||
        after.minor_number != static_cast<std::uint64_t>(minor(info.st_rdev)))
        throw std::runtime_error("UIO device identity or mapping changed");
}
}  // namespace station_uio
