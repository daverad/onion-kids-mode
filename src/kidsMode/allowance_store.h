#ifndef KID_ALLOWANCE_STORE_H
#define KID_ALLOWANCE_STORE_H
#include "allowance.h"
/* All paths are relative to a directory descriptor. The caller holds its
 * exclusive lock throughout a read/modify/write transaction (or game). */
int allowance_load(int directory, const char *name, AllowanceLedger *ledger);
bool allowance_save(int directory, AllowanceLedger *ledger);
bool allowance_atomic(int directory, const char *name, const char *data, size_t length);
#endif
