#include "allowance.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    /* Exercise temporal transitions even when bytes are not a valid ledger. */
    AllowanceClock clock = {20261109, 1794240000U, true};
    AllowanceChild child = {.daily=1, .base=300, .day=clock.day, .wall=clock.wall};
    uint64_t ms = 1000;
    AllowanceSession session = allowance_session_start(&child, clock, ms, 5);
    int remaining = 300;
    for (size_t i = 0; i < size && i < 64; ++i) {
        ms += (data[i] & 1U) != 0 ? 250U : 5000U;
        AllowanceStep step = allowance_session_advance(&child, &session, clock, ms,
            (data[i] & 2U) != 0, (data[i] & 4U) != 0, 5);
        assert(step.remaining <= remaining && step.remaining >= 0);
        assert(session.prepaid <= 5 && child.used <= 300);
        remaining = step.remaining;
    }
    allowance_session_finish(&child, &session);
    unsigned used = child.used;
    allowance_session_finish(&child, &session);
    assert(child.used == used);
    AllowanceLedger ledger;
    if (allowance_parse((const char *)data, size, &ledger)) {
        char encoded[AL_BUFFER]; size_t length;
        assert(allowance_format(&ledger, encoded, sizeof(encoded), &length));
        assert(length == size && memcmp(data, encoded, size) == 0);
        for (size_t i = 0; i < ledger.count; ++i) {
            AllowanceChild *record = &ledger.children[i];
            int before = allowance_remaining(record);
            unsigned lease = allowance_reserve(record, 5);
            assert(lease <= 5);
            allowance_refund(record, lease);
            assert(allowance_remaining(record) == before);
        }
    }
    return 0;
}
