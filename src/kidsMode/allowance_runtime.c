#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "allowance_runtime.h"
#include "allowance_store.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void interrupted(int sig) { (void)sig; stopping = 1; }
static bool decimal(const char *s, uint64_t max, uint64_t *value)
{
    if (s == NULL || *s == '\0' || strlen(s) > 20) return false;
    uint64_t n = 0;
    for (; *s != '\0'; ++s) {
        if (*s < '0' || *s > '9') return false;
        unsigned d = (unsigned)(*s - '0');
        if (n > max / 10U || (n == max / 10U && d > max % 10U)) return false;
        n = n * 10U + d;
    }
    *value = n; return true;
}
static AllowanceClock clock_now(void)
{
    time_t now = time(NULL);
    struct tm local;
    AllowanceClock clock = {0};
    clock.trusted = access("/tmp/rtc_available", F_OK) == 0 ||
        access("/tmp/kidmode_rtc_available", F_OK) == 0 ||
        access("/tmp/ntp_synced", F_OK) == 0 ||
        access("/tmp/kidmode_clock_confirmed", F_OK) == 0;
#ifdef ALLOWANCE_TESTING
    const char *clock_path = getenv("ALLOWANCE_CLOCK");
    if (clock_path != NULL) {
        FILE *file = fopen(clock_path, "r");
        long long epoch = 0; unsigned trusted = 0;
        if (file == NULL) return clock;
        int fields = fscanf(file, "%lld %u", &epoch, &trusted);
        if (fclose(file) != 0 || fields != 2) return clock;
        now = (time_t)epoch; clock.trusted = trusted == 1;
    }
#endif
    if (now > 0 && localtime_r(&now, &local) != NULL) {
        clock.day = allowance_day(local.tm_year + 1900, local.tm_mon + 1, local.tm_mday);
        clock.wall = (uint64_t)now;
    }
    const char *zone = getenv("TZ");
    if (zone == NULL || *zone == '\0' || strlen(zone) > 128U) {
        clock.day = 0; clock.trusted = false;
    }
    return clock;
}
static uint64_t monotonic_ms(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0 || t.tv_sec < 0) return 0;
    return (uint64_t)t.tv_sec * 1000U + (uint64_t)t.tv_nsec / 1000000U;
}
static unsigned midnight_limit(void)
{
    time_t now = time(NULL);
    struct tm next;
    if (localtime_r(&now, &next) == NULL) return 1;
    ++next.tm_mday; next.tm_hour = 0; next.tm_min = 0; next.tm_sec = 0; next.tm_isdst = -1;
    time_t midnight = mktime(&next);
    double delta = difftime(midnight, now);
    return delta > 0 && delta < (double)AL_LEASE ? (unsigned)delta : AL_LEASE;
}
static int awake(void)
{
    const char *path = "/sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/duty_cycle";
#ifdef ALLOWANCE_TESTING
    const char *override = getenv("ALLOWANCE_BRIGHTNESS");
    if (override != NULL) path = override;
#endif
    FILE *file = fopen(path, "r");
    if (file == NULL) return -1;
    unsigned value = 0;
    int result = fscanf(file, "%u", &value);
    if (fclose(file) != 0 || result != 1) return -1;
    return value > 0 ? 1 : 0;
}
static bool publish(int remaining)
{
    char text[32];
    int n = snprintf(text, sizeof(text), "%d\n", remaining);
    int directory = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) return false;
    bool result = n > 0 && (size_t)n < sizeof(text) && allowance_atomic(directory, "kidmode_remaining", text, (size_t)n);
    if (close(directory) != 0) result = false;
    return result;
}
/* RetroArch's command socket is local even when Wi-Fi is disabled. Send
 * directly: spawning sendUDP hid exec failures and blocked the accounting
 * loop on an external process. UDP acceptance is not a display receipt. */
static void message(const char *text)
{
    uint64_t port = 55355;
#ifdef ALLOWANCE_TESTING
    const char *override = getenv("ALLOWANCE_COMMAND_PORT");
    if (override != NULL && (!decimal(override, 65535, &port) || port == 0)) return;
#endif
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("Kids Mode command socket"); return; }
    size_t length = strlen(text);
    if (sendto(fd, text, length, MSG_DONTWAIT,
            (const struct sockaddr *)&address, sizeof(address)) != (ssize_t)length)
        perror("Kids Mode command send");
    if (close(fd) != 0) perror("Kids Mode command close");
}
static bool read_id(int profile, char id[AL_ID_SIZE])
{
    char text[AL_ID_SIZE + 1U] = {0};
    int fd = openat(profile, ".allowance-id", O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return false;
    ssize_t n = read(fd, text, sizeof(text));
    bool ok = close(fd) == 0 && n == (ssize_t)AL_ID_SIZE && text[AL_ID_SIZE - 1U] == '\n';
    text[AL_ID_SIZE - 1U] = '\0';
    if (!ok || !allowance_id_valid(text)) return false;
    memcpy(id, text, AL_ID_SIZE); return true;
}
static bool create_id(int profile, char id[AL_ID_SIZE])
{
    unsigned char bytes[8];
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return false;
    ssize_t n = read(fd, bytes, sizeof(bytes));
    bool ok = close(fd) == 0 && n == (ssize_t)sizeof(bytes);
    if (!ok) return false;
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(bytes); ++i) { id[i * 2U] = hex[bytes[i] >> 4]; id[i * 2U + 1U] = hex[bytes[i] & 15U]; }
    id[AL_ID_SIZE - 1U] = '\0';
    char line[AL_ID_SIZE]; memcpy(line, id, sizeof(line)); line[AL_ID_SIZE - 1U] = '\n';
    return allowance_atomic(profile, ".allowance-id", line, sizeof(line));
}

/* The lock is held by this supervisor while a game runs. Parent edits cannot
 * race with accounting, and no worker/thread survives a game session. Time is
 * prepaid in <=5 second leases. An abrupt power cut can cost at most one
 * lease; an orderly exit refunds the unused part. */
static int supervise(int directory, AllowanceLedger *ledger, AllowanceChild *c, const char *command)
{
    if (c->daily == 0 || allowance_remaining(c) <= 0 || awake() < 0) return 2;
    uint64_t now = monotonic_ms();
    if (now == 0) return 2;
    AllowanceSession session = allowance_session_start(c, clock_now(), now, midnight_limit());
    if (session.prepaid == 0 || !allowance_save(directory, ledger)) return 2;
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = interrupted; sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0) return 2;
    pid_t game = fork();
    if (game < 0) { allowance_session_finish(c, &session); (void)allowance_save(directory, ledger); return 2; }
    if (game == 0) {
        (void)setpgid(0, 0);
        const char *preload = getenv("KIDMODE_GAME_LD_PRELOAD");
        if (preload != NULL && setenv("LD_PRELOAD", preload, 1) != 0) _exit(127);
        if (unsetenv("KIDMODE_GAME_LD_PRELOAD") != 0) _exit(127);
        execl("/bin/sh", "sh", command, (char *)NULL); _exit(127);
    }
    (void)setpgid(game, game);
    bool failed = false;
    unsigned warning = 0, warning_sends = 0;
    int warning_next = 0;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(game, &status, WNOHANG);
        if (result == game) break;
        if (result < 0 && errno != EINTR) { failed = true; break; }
        struct timespec pause = {0, 250000000}; (void)nanosleep(&pause, NULL);
        now = monotonic_ms();
        int lit = awake();
        if (now == 0) {
            (void)kill(-game, SIGKILL);
            while (waitpid(game, &status, 0) < 0 && errno == EINTR) { }
            failed = true;
            break;
        }
        if (lit < 0) failed = true;
        AllowanceStep step = allowance_session_advance(c, &session, clock_now(), now,
            lit != 0, failed || stopping, midnight_limit());
        if (step.commit && !allowance_save(directory, ledger)) failed = true;
        if (!publish(step.remaining)) failed = true;
        /* Three bounded sends, two gameplay seconds apart: cover startup
         * packet loss and keep the ~3-second OSD readable. Remaining time
         * freezes during sleep, so wake never causes a burst of stale sends. */
        if (step.warning != 0) {
            warning = step.warning; warning_sends = 3; warning_next = step.remaining;
        }
        if (step.action != AL_PLAYING || step.remaining > (int)(warning * 60U))
            warning_sends = 0;
        if (warning_sends > 0 && lit > 0 && step.remaining <= warning_next) {
            message(warning == 5 ? "SHOW_MSG 5 minutes left today" : "SHOW_MSG 1 minute left today");
            --warning_sends; warning_next = step.remaining - 2;
        }
        switch (step.action) {
        case AL_QUIT:
            message(failed ? "SHOW_MSG Allowance storage error - exiting" : "SHOW_MSG Time's up - returning to Kids Mode");
            message("QUIT");
            break;
        case AL_RETRY_QUIT: message("QUIT"); break;
        /* Forced termination cannot promise a completed save. */
        case AL_TERM: (void)kill(-game, SIGTERM); failed = true; break;
        case AL_KILL: (void)kill(-game, SIGKILL); failed = true; break;
        case AL_PLAYING: break;
        }
    }
    allowance_session_finish(c, &session);
    if (!allowance_save(directory, ledger) || !publish(allowance_remaining(c))) failed = true;
    return failed || !WIFEXITED(status) ? 2 : WEXITSTATUS(status);
}

int allowance_main(int argc, char **argv)
{
    /* argv: --allowance directory profile command [value generation].
     * Only the shell's authenticated parent flow invokes policy mutations. */
    if (argc < 5 || argc > 7) return 2;
    for (int i = 1; i < argc; ++i) if (strlen(argv[i]) > 512U) return 2;
    const char *operation = argv[4];
    bool enroll = strcmp(operation, "enroll") == 0;
    if (enroll && mkdir(argv[2], 0700) != 0 && errno != EEXIST) return 2;
    int directory = open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return 2;
    int lock = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    int profile = open(argv[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int rc = 2;
    if (lock < 0 || profile < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) goto cleanup;
    AllowanceLedger ledger = {0};
    int loaded = allowance_load(directory, "state.v1", &ledger);
    char id[AL_ID_SIZE] = {0};
    bool has_id = read_id(profile, id);
    if (loaded == 1 && enroll && !has_id && faccessat(directory, "previous.v1", F_OK, 0) != 0) {
        if (!allowance_save(directory, &ledger)) goto cleanup;
    } else if (loaded != 0) goto cleanup;
    AllowanceChild *child = NULL;
    if (has_id) for (size_t i = 0; i < ledger.count; ++i)
        if (strcmp(ledger.children[i].id, id) == 0) child = &ledger.children[i];
    if (child == NULL && enroll && ledger.count < AL_CHILDREN) {
        if (!has_id) {
            /* A malformed ID is not a new child. Never silently replace it. */
            if (faccessat(profile, ".allowance-id", F_OK, 0) == 0 || !create_id(profile, id)) goto cleanup;
        }
        for (size_t i = 0; i < ledger.count; ++i) if (strcmp(ledger.children[i].id, id) == 0) goto cleanup;
        child = &ledger.children[ledger.count++]; memcpy(child->id, id, sizeof(id));
        (void)allowance_observe(child, clock_now(), false);
        if (!allowance_save(directory, &ledger)) goto cleanup;
    }
    if (child == NULL) goto cleanup;
    /* Re-establish continuity from a trustworthy, non-backward clock between
     * games. Same-day recovery preserves usage/bonus; a later day resets once.
     * The running supervisor still detects jumps against monotonic elapsed time.
     * Commit recovery before reporting a fresh budget or launching a game. */
    AllowanceClock clock = clock_now();
    bool recovered = clock.trusted && clock.day >= child->day && clock.wall >= child->wall;
    bool changed = allowance_observe(child, clock, recovered);
    if (changed && !allowance_save(directory, &ledger)) goto cleanup;
    if ((strcmp(operation, "status") == 0 || enroll) && argc == 5) {
        printf("%d %u %u %u %" PRIu64 " %u %u\n", allowance_remaining(child), child->daily, child->base / 60U, child->uncertain, ledger.generation, child->used, child->day);
        rc = 0;
    } else if (strcmp(operation, "run") == 0 && argc == 6) {
        rc = supervise(directory, &ledger, child, argv[5]);
    } else if (argc == 7) {
        uint64_t value, generation;
        if (!decimal(argv[5], 120, &value) || !decimal(argv[6], INT64_MAX, &generation) || generation != ledger.generation) goto cleanup;
        if (strcmp(operation, "daily") == 0) { if (!allowance_base(child, (unsigned)value)) goto cleanup; }
        else if (strcmp(operation, "bonus") == 0) { if (!allowance_bonus(child, (unsigned)value)) goto cleanup; }
        else if (strcmp(operation, "off") == 0) child->daily = 0;
        else if (strcmp(operation, "confirm") == 0) {
            clock = clock_now(); if (clock.day == 0) goto cleanup;
            for (size_t i = 0; i < ledger.count; ++i)
                (void)allowance_observe(&ledger.children[i], clock, true);
        } else goto cleanup;
        if (allowance_save(directory, &ledger)) {
            rc = 0;
            if (strcmp(operation, "confirm") == 0) {
                int marker = open("/tmp/kidmode_clock_confirmed", O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
                if (marker < 0 || close(marker) != 0) rc = 2;
            }
        }
    }
cleanup:
    if (profile >= 0) (void)close(profile);
    if (lock >= 0) (void)close(lock);
    (void)close(directory);
    if (rc == 2) fprintf(stderr, "Kids Mode allowance: operation refused; preserve the ledger and inspect storage/clock.\n");
    return rc;
}
#ifdef ALLOWANCE_STANDALONE
int main(int argc, char **argv) { return allowance_main(argc, argv); }
#endif
