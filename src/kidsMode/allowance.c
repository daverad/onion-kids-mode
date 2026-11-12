#include "allowance.h"
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

bool allowance_id_valid(const char *id)
{
    if (id == NULL) return false;
    for (size_t i = 0; i < AL_ID_SIZE - 1U; ++i)
        if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'a' && id[i] <= 'f'))) return false;
    return id[AL_ID_SIZE - 1U] == '\0';
}

uint32_t allowance_day(int year, int month, int day)
{
    static const int days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
    if (year < 2020 || year > 2099 || month < 1 || month > 12 || day < 1) return 0;
    int max = days[month - 1] + ((month == 2 && year % 4 == 0) ? 1 : 0);
    if (day > max) return 0;
    return (uint32_t)(year * 10000 + month * 100 + day);
}

bool allowance_observe(AllowanceChild *c, AllowanceClock t, bool confirm)
{
    AllowanceChild before = *c;
    if (t.day == 0 || t.wall == 0) {
        c->uncertain = 1;
    } else if (confirm) {
        if (t.day > c->day) { c->used = 0; c->bonus = 0; c->warned = 0; }
        c->day = t.day; c->wall = t.wall; c->uncertain = 0;
    } else if (t.day < c->day || t.wall < c->wall) {
        c->uncertain = 1;
    } else {
        if (t.day > c->day) {
            if (t.trusted && c->uncertain == 0) {
                c->day = t.day; c->used = 0; c->bonus = 0; c->warned = 0;
            } else c->uncertain = 1;
        }
        if (t.wall > c->wall) c->wall = t.wall;
    }
    return before.day != c->day || before.used != c->used ||
        before.bonus != c->bonus || before.uncertain != c->uncertain || before.warned != c->warned;
}

int allowance_remaining(const AllowanceChild *c)
{
    if (c->daily == 0) return -1;
    uint32_t budget = c->base + c->bonus;
    return budget > c->used ? (int)(budget - c->used) : 0;
}

bool allowance_base(AllowanceChild *c, unsigned minutes)
{
    if (minutes > AL_BASE_MAX / 60U || minutes % 5U != 0) return false;
    c->base = minutes * 60U; c->daily = 1;
    if (allowance_remaining(c) > 300) c->warned &= ~1U;
    if (allowance_remaining(c) > 60) c->warned &= ~2U;
    return true;
}

bool allowance_bonus(AllowanceChild *c, unsigned minutes)
{
    if (minutes == 0 || minutes > 120U || minutes % 5U != 0 ||
        c->bonus > AL_DAY_SECONDS - minutes * 60U) return false;
    c->bonus += minutes * 60U;
    if (allowance_remaining(c) > 300) c->warned &= ~1U;
    if (allowance_remaining(c) > 60) c->warned &= ~2U;
    return true;
}

unsigned allowance_reserve(AllowanceChild *c, unsigned seconds)
{
    int remaining = allowance_remaining(c);
    if (remaining <= 0) return 0;
    if (seconds > AL_LEASE) seconds = AL_LEASE;
    if (seconds > (unsigned)remaining) seconds = (unsigned)remaining;
    c->used += seconds;
    return seconds;
}
void allowance_refund(AllowanceChild *c, unsigned seconds)
{
    if (seconds > AL_LEASE || seconds > c->used) return;
    c->used -= seconds;
}
unsigned allowance_warning(AllowanceChild *c, int before, int after)
{
    unsigned result = 0;
    if (before >= 300 && after <= 300 && (c->warned & 1U) == 0) { c->warned |= 1U; result = 5; }
    if (before >= 60 && after <= 60 && (c->warned & 2U) == 0) { c->warned |= 2U; result = 1; }
    return result;
}

AllowanceSession allowance_session_start(AllowanceChild *c, AllowanceClock clock,
    uint64_t mono_ms, unsigned limit)
{
    AllowanceSession s = {.sampled_ms=mono_ms, .observed_wall=clock.wall,
        .observed_day=clock.day, .remaining=allowance_remaining(c)};
    s.prepaid = allowance_reserve(c, limit);
    return s;
}

void allowance_session_finish(AllowanceChild *c, AllowanceSession *s)
{
    allowance_refund(c, s->prepaid);
    s->prepaid = 0;
    s->fraction_ms = 0;
}

AllowanceStep allowance_session_advance(AllowanceChild *c, AllowanceSession *s,
    AllowanceClock clock, uint64_t mono_ms, bool awake, bool stopping, unsigned limit)
{
    AllowanceStep step = {0};
    uint64_t gap = mono_ms >= s->sampled_ms ? mono_ms - s->sampled_ms : UINT64_MAX;
    s->sampled_ms = mono_ms;
    /* keymon stops this process during sleep. Only short, observed awake
     * intervals count, including for an emulator's save/exit grace period. */
    unsigned active_ms = awake && gap <= 2000U ? (unsigned)gap : 0;
    if (!stopping && active_ms != 0) s->fraction_ms += active_ms;
    else s->fraction_ms = 0;
    unsigned elapsed = s->fraction_ms / 1000U;
    s->fraction_ms %= 1000U;
    if (elapsed > s->prepaid) elapsed = s->prepaid;
    s->prepaid -= elapsed;
    if (clock.day != s->observed_day || !awake || gap > 2000U || stopping) {
        step.commit = s->prepaid != 0;
        allowance_session_finish(c, s);
    }
    if (clock.wall < s->observed_wall || (clock.wall > s->observed_wall &&
        clock.wall - s->observed_wall > gap / 1000U + 2U)) {
        step.commit |= c->uncertain == 0;
        c->uncertain = 1;
    }
    s->observed_wall = clock.wall;
    s->observed_day = clock.day;
    step.commit |= allowance_observe(c, clock, false);
    step.remaining = allowance_remaining(c) + (int)s->prepaid;
    step.warning = allowance_warning(c, s->remaining, step.remaining);
    step.commit |= step.warning != 0;
    s->remaining = step.remaining;

    if (s->exit_phase == AL_PLAYING) {
        if (step.remaining <= 0 || stopping) {
            s->exit_phase = AL_QUIT;
            step.action = AL_QUIT;
        } else if (s->prepaid == 0 && awake) {
            s->prepaid = allowance_reserve(c, limit);
            step.commit |= s->prepaid != 0;
        }
    } else {
        s->exit_awake_ms += active_ms;
        if (s->exit_awake_ms > 12000U) s->exit_awake_ms = 12000U;
        switch (s->exit_phase) {
        case AL_QUIT:
            if (s->exit_awake_ms >= 3000U) step.action = AL_RETRY_QUIT;
            break;
        case AL_RETRY_QUIT:
            if (s->exit_awake_ms >= 8000U) step.action = AL_TERM;
            break;
        case AL_TERM:
            if (s->exit_awake_ms >= 12000U) step.action = AL_KILL;
            break;
        case AL_PLAYING: case AL_KILL: break;
        }
        if (step.action != AL_PLAYING) s->exit_phase = step.action;
    }
    return step;
}

static uint32_t checksum(const char *data, size_t length)
{
    uint32_t value = UINT32_C(2166136261);
    for (size_t i = 0; i < length; ++i) { value ^= (unsigned char)data[i]; value *= UINT32_C(16777619); }
    return value;
}
static bool number(const char **p, const char *end, uint64_t max, uint64_t *out, char separator)
{
    uint64_t n = 0;
    const char *start = *p;
    while (*p < end && **p >= '0' && **p <= '9') {
        unsigned digit = (unsigned)(**p - '0');
        if (n > max / 10U || (n == max / 10U && digit > max % 10U)) return false;
        n = n * 10U + digit; ++*p;
    }
    if (*p == start || *p == end || **p != separator || (*p - start > 1 && *start == '0')) return false;
    ++*p; *out = n; return true;
}
static bool valid_child(const AllowanceChild *c)
{
    return allowance_id_valid(c->id) && c->daily <= 1 && c->base <= AL_BASE_MAX && c->base % 300U == 0 &&
        c->used <= AL_DAY_SECONDS + AL_BASE_MAX && c->bonus <= AL_DAY_SECONDS && c->bonus % 300U == 0 &&
        (c->day == 0 || allowance_day((int)(c->day / 10000U), (int)(c->day / 100U % 100U), (int)(c->day % 100U)) == c->day) &&
        c->uncertain <= 1 && c->warned <= 3 && c->wall <= UINT64_C(4102444800);
}
bool allowance_parse(const char *data, size_t length, AllowanceLedger *out)
{
    if (data == NULL || out == NULL || length < 10 || length >= AL_BUFFER) return false;
    AllowanceLedger result = {0};
    const char *p = data, *end = data + length;
    uint64_t value;
    if (memcmp(p, "KDA1 ", 5) != 0) return false;
    p += 5;
    if (!number(&p, end, INT64_MAX, &result.generation, ' ') ||
        !number(&p, end, AL_CHILDREN, &value, '\n')) return false;
    result.count = (size_t)value;
    for (size_t i = 0; i < result.count; ++i) {
        AllowanceChild *c = &result.children[i];
        if ((size_t)(end - p) < AL_ID_SIZE) return false;
        memcpy(c->id, p, AL_ID_SIZE - 1U); p += AL_ID_SIZE - 1U;
        if (*p++ != ' ') return false;
        uint32_t *fields[] = {&c->daily, &c->base, &c->used, &c->bonus, &c->day, &c->uncertain, &c->warned};
        for (size_t k = 0; k < sizeof(fields) / sizeof(fields[0]); ++k) {
            if (!number(&p, end, UINT32_MAX, &value, ' ')) return false;
            *fields[k] = (uint32_t)value;
        }
        if (!number(&p, end, UINT64_C(4102444800), &c->wall, '\n') || !valid_child(c)) return false;
        for (size_t k = 0; k < i; ++k) if (strcmp(c->id, result.children[k].id) == 0) return false;
    }
    uint32_t expected = checksum(data, (size_t)(p - data));
    if (!number(&p, end, UINT32_MAX, &value, '\n') || p != end || value != expected) return false;
    *out = result;
    return true;
}

bool allowance_format(const AllowanceLedger *s, char *out, size_t capacity, size_t *length)
{
    if (s == NULL || out == NULL || length == NULL || s->count > AL_CHILDREN || s->generation > INT64_MAX || capacity == 0) return false;
    int n = snprintf(out, capacity, "KDA1 %" PRIu64 " %zu\n", s->generation, s->count);
    if (n < 0 || (size_t)n >= capacity) return false;
    size_t used = (size_t)n;
    for (size_t i = 0; i < s->count; ++i) {
        const AllowanceChild *c = &s->children[i];
        if (!valid_child(c)) return false;
        for (size_t k = 0; k < i; ++k) if (strcmp(c->id, s->children[k].id) == 0) return false;
        n = snprintf(out + used, capacity - used, "%s %u %u %u %u %u %u %u %" PRIu64 "\n",
            c->id, c->daily, c->base, c->used, c->bonus, c->day, c->uncertain, c->warned, c->wall);
        if (n < 0 || (size_t)n >= capacity - used) return false;
        used += (size_t)n;
    }
    n = snprintf(out + used, capacity - used, "%u\n", checksum(out, used));
    if (n < 0 || (size_t)n >= capacity - used) return false;
    *length = used + (size_t)n;
    return true;
}
