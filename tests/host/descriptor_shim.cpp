#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

// Link-wrapped only in the host addon; never compiled into the HAP. Exercise
// production inspection against the exact syscall failure seen on the phone.
extern "C" int __real_fstat(int fd, struct stat *metadata);
extern "C" int __wrap_fstat(int fd, struct stat *metadata)
{
    const char *fault = std::getenv("HARMONY_TEST_DESCRIPTOR_FAULT");
    if (fault) {
        if (std::strcmp(fault, "EACCES") == 0) { errno = EACCES; return -1; }
        if (std::strcmp(fault, "EPERM") == 0) { errno = EPERM; return -1; }
        if (std::strcmp(fault, "EBADF") == 0) { errno = EBADF; return -1; }
        if (std::strcmp(fault, "EIO") == 0) { errno = EIO; return -1; }
    }
    return __real_fstat(fd, metadata);
}
