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
            ",\"checkStage\":\"duplicate\",\"error\":\"Cannot duplicate VPN descriptor\"}";
    }
    struct stat metadata {};
    const int flags = fcntl(duplicate, F_GETFL);
    const int flagsError = flags < 0 ? errno : 0;
    const int statResult = fstat(duplicate, &metadata);
    const int statError = statResult < 0 ? errno : 0;
    // Duplication and F_GETFL establish FD validity/access. Metadata queries
    // can be separately denied by the application sandbox (device EACCES).
    const bool valid = flags >= 0;
    const bool readWrite = valid && (flags & O_ACCMODE) == O_RDWR;
    const bool regularFile = statResult == 0 && S_ISREG(metadata.st_mode);
    const bool metadataRestricted = statResult < 0 && (statError == EACCES || statError == EPERM);
    const int closeResult = close(duplicate);
    const int closeError = closeResult < 0 ? errno : 0;
    const bool ok = valid && readWrite && (statResult == 0 || metadataRestricted) && !regularFile && closeResult == 0;
    const int access = flags >= 0 ? flags & O_ACCMODE : -1;
    const char *accessMode = access == O_RDWR ? "read-write" :
        access == O_RDONLY ? "read-only" : access == O_WRONLY ? "write-only" : "unknown";
    const char *fileType = statResult < 0 ? "unknown" :
        S_ISCHR(metadata.st_mode) ? "character" : S_ISREG(metadata.st_mode) ? "regular" :
        S_ISSOCK(metadata.st_mode) ? "socket" : S_ISFIFO(metadata.st_mode) ? "fifo" :
        S_ISDIR(metadata.st_mode) ? "directory" : "other";
    std::string error;
    const char *checkStage = "complete";
    if (flags < 0) { error = "VPN descriptor F_GETFL failed"; checkStage = "getFlags"; }
    else if (statResult < 0 && !metadataRestricted) { error = "VPN descriptor fstat failed"; checkStage = "stat"; }
    else if (!readWrite) {
        error = std::string("VPN descriptor access mode is ") + accessMode + " (flags=" + std::to_string(flags) + ")";
        checkStage = "accessMode";
    } else if (regularFile) {
        error = "VPN descriptor is reported as a regular file; packet-device compatibility is unverified";
        checkStage = "fileType";
    }
    if (closeResult < 0) {
        error += "; duplicate close failed";
        if (valid && readWrite && (statResult == 0 || metadataRestricted) && !regularFile) { checkStage = "closeDuplicate"; }
    }
    return std::string("{\"ok\":") + (ok ? "true" : "false") +
        ",\"descriptorValid\":" + (valid ? "true" : "false") +
        ",\"readWriteDescriptor\":" + (readWrite ? "true" : "false") +
        ",\"regularFile\":" + (regularFile ? "true" : "false") +
        ",\"flags\":" + std::to_string(flags) +
        ",\"accessMode\":\"" + accessMode + "\"" +
        ",\"fileType\":\"" + fileType + "\"" +
        ",\"fileMode\":" + std::to_string(metadata.st_mode) +
        ",\"flagsErrno\":" + std::to_string(flagsError) +
        ",\"statErrno\":" + std::to_string(statError) +
        ",\"metadataAvailable\":" + (statResult == 0 ? "true" : "false") +
        ",\"packetIOVerified\":false,\"warning\":\"" +
        (metadataRestricted ? "Descriptor metadata query denied by sandbox; file type and packet I/O remain unverified" : "") + "\"" +
        ",\"duplicateClosed\":" + (closeResult == 0 ? "true" : "false") +
        ",\"closeErrno\":" + std::to_string(closeError) +
        ",\"checkStage\":\"" + checkStage + "\"" +
        ",\"tunnelConnected\":false,\"error\":\"" +
        error + "\"}";
}
