#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "allowance_store.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef ALLOWANCE_TESTING
#include <stdlib.h>
static bool fault(const char *point)
{
    const char *p = getenv("ALLOWANCE_FAULT");
    const char *cut = getenv("ALLOWANCE_CUT");
    if (cut != NULL && strcmp(cut, point) == 0) _exit(97);
    if (p != NULL && strcmp(p, point) == 0) { errno = EIO; return true; }
    return false;
}
#else
static bool fault(const char *point) { (void)point; return false; }
#endif

/* FAT may not implement directory fsync. Flush the file and use syncfs on
 * Linux in that case; errors on every other operation remain fatal. */
static bool flush_directory(int fd)
{
    if (fault("directory-fsync")) return false;
    if (fsync(fd) == 0) return true;
#ifdef __linux__
    if (errno == EINVAL) return syncfs(fd) == 0;
#endif
    return false;
}

bool allowance_atomic(int directory, const char *name, const char *data, size_t length)
{
    char temp[64];
    int n = snprintf(temp, sizeof(temp), "%s.new", name);
    if (n < 0 || (size_t)n >= sizeof(temp) || strchr(name, '/') != NULL || length >= AL_BUFFER) return false;
    char phase[96];
    int phase_length = snprintf(phase, sizeof(phase), "%s:before", name);
    if (phase_length < 0 || (size_t)phase_length >= sizeof(phase) || fault(phase) || fault("open")) return false;
    int fd = openat(directory, temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    bool ok = true;
    size_t done = 0;
    while (done < length) {
        if (fault("write")) { ok = false; break; }
        ssize_t count = write(fd, data + done, length - done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = false; break; }
        done += (size_t)count;
    }
    if (ok && (fault("fsync") || fsync(fd) != 0)) ok = false;
    if (close(fd) != 0 || fault("close")) ok = false;
    if (!ok) return false;
    if (fault("rename") || renameat(directory, temp, directory, name) != 0) return false;
    phase_length = snprintf(phase, sizeof(phase), "%s:renamed", name);
    if (phase_length < 0 || (size_t)phase_length >= sizeof(phase) || fault(phase) || fault("renamed") || !flush_directory(directory)) return false;
    return !fault("durable");
}

/* 0 valid, 1 missing, -1 unreadable/invalid. Missing is only initial state
 * when enrollment was explicitly requested from the PIN-protected flow. */
int allowance_load(int directory, const char *name, AllowanceLedger *ledger)
{
    char buffer[AL_BUFFER];
    if (fault("read-open")) return -1;
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT ? 1 : -1;
    struct stat st;
    bool ok = !fault("stat") && fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (off_t)sizeof(buffer);
    size_t used = 0;
    while (ok && used < sizeof(buffer)) {
        if (fault("read")) { ok = false; break; }
        ssize_t count = read(fd, buffer + used, sizeof(buffer) - used);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = false; break; }
        if (count == 0) break;
        used += (size_t)count;
    }
    if (close(fd) != 0) ok = false;
    return ok && allowance_parse(buffer, used, ledger) ? 0 : -1;
}

bool allowance_save(int directory, AllowanceLedger *ledger)
{
    char buffer[AL_BUFFER];
    size_t length;
    AllowanceLedger previous;
    int result = allowance_load(directory, "state.v1", &previous);
    if (result < 0 || ledger->generation >= INT64_MAX) return false;
    if (result == 0) {
        if (!allowance_format(&previous, buffer, sizeof(buffer), &length) ||
            !allowance_atomic(directory, "previous.v1", buffer, length)) return false;
    }
    ++ledger->generation;
    if (!allowance_format(ledger, buffer, sizeof(buffer), &length) ||
        !allowance_atomic(directory, "state.v1", buffer, length)) return false;
    return true;
}
