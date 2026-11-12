/* Deliberately broken, separate negative controls. Never linked into kidui. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* A stale stack/register pointer can make conservative LSan regard a lost
 * allocation as reachable. Store only in this volatile global, then clear
 * it explicitly before returning to main's zero return value. */
static void *volatile lost;
static void leak(void)
{
    lost = malloc(123);
    if (lost == NULL) exit(2);
    lost = NULL;
}
int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    if (strcmp(argv[1], "uaf") == 0) {
        int *p = malloc(sizeof(*p)); if (p == NULL) return 2;
        *p = 7; free(p); printf("%d\n", *p);
    } else if (strcmp(argv[1], "overflow") == 0) {
        volatile int n = INT_MAX; ++n;
    } else if (strcmp(argv[1], "leak") == 0) leak();
    else return 2;
    return 0;
}
