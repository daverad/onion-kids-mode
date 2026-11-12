#include "allowance.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void session_tests(void)
{
    AllowanceClock clock = {20261109, 1794240000U, true};
    AllowanceChild c = {.daily=1, .base=300, .day=clock.day, .wall=clock.wall};
    AllowanceSession s = allowance_session_start(&c, clock, 1000, 5);
    assert(c.used == 5 && s.prepaid == 5);
    AllowanceStep step = allowance_session_advance(&c, &s, clock, 2000, true, false, 5);
    assert(step.remaining == 299 && s.prepaid == 4 && step.warning == 5);
    step = allowance_session_advance(&c, &s, clock, 2250, false, false, 5);
    assert(step.commit && c.used == 1 && s.prepaid == 0 && step.remaining == 299);
    step = allowance_session_advance(&c, &s, clock, 10000, true, false, 5);
    assert(step.commit && step.remaining == 299 && s.prepaid == 5);
    allowance_session_finish(&c, &s); assert(c.used == 1);
    allowance_session_finish(&c, &s); assert(c.used == 1);

    /* A date transition refunds the OLD day's reservation before resetting. */
    s = allowance_session_start(&c, clock, 10000, 1);
    clock.day++; clock.wall += 86400;
    step = allowance_session_advance(&c, &s, clock, 86410000, true, false, 5);
    assert(step.commit && c.day == clock.day && c.used == 5 && step.remaining == 300);
    clock.day--; clock.wall -= 86400;
    step = allowance_session_advance(&c, &s, clock, 86411000, true, false, 5);
    assert(step.commit && c.uncertain == 1 && step.remaining == 299);
    allowance_session_finish(&c, &s);

    /* Zero triggers exactly one action per stage; sleep does not consume the
     * emulator's save grace. A resumed emulator gets its remaining grace. */
    c.used = c.base - 1;
    s = allowance_session_start(&c, clock, 1000, 5);
    step = allowance_session_advance(&c, &s, clock, 2000, true, false, 5);
    assert(step.remaining == 0 && step.action == AL_QUIT);
    step = allowance_session_advance(&c, &s, clock, 200000, true, false, 5);
    assert(step.action == AL_PLAYING && s.exit_awake_ms == 0);
    unsigned actions[5] = {0};
    for (uint64_t ms = 200250; ms <= 215000; ms += 250) {
        step = allowance_session_advance(&c, &s, clock, ms, true, false, 5);
        actions[step.action]++;
    }
    assert(actions[AL_QUIT] == 0 && actions[AL_RETRY_QUIT] == 1 &&
        actions[AL_TERM] == 1 && actions[AL_KILL] == 1);
    c.used = 0;
    s = allowance_session_start(&c, clock, 1000, 5);
    step = allowance_session_advance(&c, &s, clock, 1250, true, true, 5);
    assert(step.commit && step.action == AL_QUIT && c.used == 0);
}

int main(void)
{
    session_tests();
    AllowanceChild child = {.id="0123456789abcdef"};
    AllowanceClock now = {20261109, 1794240000U, true};
    assert(allowance_observe(&child, now, false));
    assert(allowance_remaining(&child) == -1);
    assert(allowance_base(&child, 30));
    assert(!allowance_base(&child, 31));
    assert(!allowance_base(&child, 125));
    assert(allowance_reserve(&child, 999) == 5);
    assert(allowance_remaining(&child) == 1795);
    allowance_refund(&child, 3);
    assert(allowance_remaining(&child) == 1798);
    /* Editing a policy, turning it off, or selecting another child cannot
     * reset usage. A zero Daily budget is blocked, not unlimited. */
    assert(allowance_base(&child, 0)); assert(allowance_remaining(&child) == 0);
    assert(allowance_base(&child, 30)); assert(child.used == 2);
    child.daily = 0; assert(allowance_remaining(&child) == -1);
    assert(allowance_base(&child, 30)); assert(child.used == 2);
    assert(allowance_bonus(&child, 5)); assert(child.bonus == 300);
    assert(!allowance_bonus(&child, 121));
    assert(allowance_warning(&child, 301, 300) == 5);
    assert(allowance_warning(&child, 301, 300) == 0);
    assert(allowance_warning(&child, 61, 60) == 1);
    /* Invalid and backward dates retain balances and block automatic reset,
     * even after the date subsequently looks plausible again. */
    now.day = 0; assert(allowance_observe(&child, now, false));
    now.day = 20261110; now.wall += 86400;
    (void)allowance_observe(&child, now, false);
    assert(child.uncertain && child.day == 20261109 && child.used == 2 && child.bonus == 300);
    assert(allowance_observe(&child, now, true));
    assert(!child.uncertain && child.used == 0 && child.bonus == 0 && child.warned == 0);
    child.used = 50;
    now.day = 20261109; now.wall -= 86400;
    assert(allowance_observe(&child, now, false)); assert(child.used == 50);
    (void)allowance_observe(&child, now, true); assert(child.used == 50);
    now.day = 20261110; now.wall += 86400;
    (void)allowance_observe(&child, now, false); assert(child.used == 0);
    assert(allowance_day(2024, 2, 29) == 20240229);
    assert(allowance_day(2023, 2, 29) == 0);
    assert(allowance_day(2026, 13, 1) == 0);
    assert(allowance_day(2019, 12, 31) == 0);
    AllowanceLedger ledger = {.generation=17,.count=1}, decoded;
    ledger.children[0] = child;
    char buffer[AL_BUFFER]; size_t length;
    assert(allowance_format(&ledger, buffer, sizeof(buffer), &length));
    assert(allowance_parse(buffer, length, &decoded));
    assert(decoded.generation == 17 && decoded.count == 1 && decoded.children[0].used == 0);
    for (size_t i = 0; i < length; ++i) {
        assert(!allowance_parse(buffer, i, &decoded));
        char saved = buffer[i]; buffer[i] = '\0';
        assert(!allowance_parse(buffer, length, &decoded)); buffer[i] = saved;
    }
    for (size_t capacity = 0; capacity <= length; ++capacity)
        assert(!allowance_format(&ledger, buffer, capacity, &length));
    puts("allowance policy and bounded codec: passed");
    return 0;
}
