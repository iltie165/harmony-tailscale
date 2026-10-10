#include "vpn_descriptor.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

std::string InspectVpnDescriptor(int fd)
{
    const int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (duplicate < 0) {
        const int failure = errno;
        return "{\"ok\":false,\"descriptorValid\":false,\"readWriteDescriptor\":false,"
            "\"tunnelConnected\":false,\"errno\":" + std::to_string(failure) +
            ",\"error\":\"Cannot duplicate VPN descriptor\"}";
    }
    struct stat metadata {};
    const int flags = fcntl(duplicate, F_GETFL);
    const bool valid = flags >= 0 && fstat(duplicate, &metadata) == 0;
    const bool readWrite = valid && (flags & O_ACCMODE) == O_RDWR;
    const bool regularFile = valid && S_ISREG(metadata.st_mode);
    const bool ok = valid && readWrite && !regularFile;
    close(duplicate);
    return std::string("{\"ok\":") + (ok ? "true" : "false") +
        ",\"descriptorValid\":" + (valid ? "true" : "false") +
        ",\"readWriteDescriptor\":" + (readWrite ? "true" : "false") +
        ",\"regularFile\":" + (regularFile ? "true" : "false") +
        ",\"tunnelConnected\":false,\"error\":\"" +
        (ok ? "" : "Descriptor is not a readable/writable VPN candidate") + "\"}";
}
