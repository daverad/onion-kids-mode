#ifndef KID_ALLOWANCE_H
#define KID_ALLOWANCE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AL_CHILDREN 32U
#define AL_BUFFER 8192U
#define AL_DAY_SECONDS 86400U
#define AL_BASE_MAX 7200U
#define AL_ID_SIZE 17U
#define AL_LEASE 5U

typedef struct {
    char id[AL_ID_SIZE];
    uint32_t daily, base, used, bonus, day, uncertain, warned;
    uint64_t wall;
} AllowanceChild;
typedef struct {
    uint64_t generation;
    size_t count;
    AllowanceChild children[AL_CHILDREN];
} AllowanceLedger;
typedef struct {
    uint32_t day;
    uint64_t wall;
    bool trusted;
} AllowanceClock;

/* Pointers below are borrowed, non-null and retained for no longer than the
 * call. Child objects must satisfy the codec's semantic bounds before policy
 * calls. IDs are NUL-terminated strings (fixed records provide 17 bytes).
 * No function allocates memory or transfers ownership. */
bool allowance_id_valid(const char *id);
uint32_t allowance_day(int year, int month, int day);
bool allowance_observe(AllowanceChild *child, AllowanceClock clock, bool confirm);
int allowance_remaining(const AllowanceChild *child);
bool allowance_base(AllowanceChild *child, unsigned minutes);
bool allowance_bonus(AllowanceChild *child, unsigned minutes);
unsigned allowance_reserve(AllowanceChild *child, unsigned seconds);
void allowance_refund(AllowanceChild *child, unsigned seconds);
unsigned allowance_warning(AllowanceChild *child, int before, int after);
/* A session owns one prepaid lease. Steps describe durable changes and
 * one-shot effects; the runtime owns all I/O and process handling. */
typedef enum { AL_PLAYING, AL_QUIT, AL_RETRY_QUIT, AL_TERM, AL_KILL } AllowanceExit;
typedef struct {
    unsigned prepaid, fraction_ms, exit_awake_ms;
    uint64_t sampled_ms, observed_wall;
    uint32_t observed_day;
    int remaining;
    AllowanceExit exit_phase;
} AllowanceSession;
typedef struct {
    bool commit;
    int remaining;
    unsigned warning;
    AllowanceExit action;
} AllowanceStep;
AllowanceSession allowance_session_start(AllowanceChild *child, AllowanceClock clock,
    uint64_t mono_ms, unsigned limit);
AllowanceStep allowance_session_advance(AllowanceChild *child, AllowanceSession *session,
    AllowanceClock clock, uint64_t mono_ms, bool awake, bool stopping, unsigned limit);
void allowance_session_finish(AllowanceChild *child, AllowanceSession *session);

/* Strict, bounded, allocation-free versioned text codec. All integers are
 * decimal, IDs are hex, and a checksum detects torn/corrupt records. Parsing
 * never mutates the destination unless the complete input is valid. */
bool allowance_parse(const char *data, size_t length, AllowanceLedger *out);
bool allowance_format(const AllowanceLedger *ledger, char *out, size_t capacity, size_t *length);
#endif
