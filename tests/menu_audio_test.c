/* Exercise the production lifetime boundary with deterministic mixer/device
 * faults. Actual theme decoding and device sound are qualified separately. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t Uint32;
typedef struct { int tag; } Mix_Chunk;
#define AUDIO_S16SYS 0x8010
#define MIX_MAX_VOLUME 128
static struct { int volume, bgm_volume; } settings = {10, 10};
static Mix_Chunk sample = {1};
static Mix_Chunk *asset = &sample;
static bool opened, muted, fail_open, playing;
static unsigned opens, closes, plays, polls, reads, loads;
static int gain;
static Uint32 now;

static int Mix_QuerySpec(void *a, void *b, void *c)
{ (void)a; (void)b; (void)c; return opened ? 1 : 0; }
static void Mix_HaltChannel(int channel)
{ assert(channel == 0); playing = false; }
static void Mix_CloseAudio(void)
{ assert(opened); opened = false; closes++; }
static Mix_Chunk *resource_getSoundChange(void)
{ loads++; return asset; }
static void _settings_load_mainui(void) { reads++; }
static bool config_flag_get(const char *flag)
{ assert(strcmp(flag, ".muteVolume") == 0); return muted; }
static int Mix_OpenAudio(int rate, int format, int channels, int size)
{
    assert(rate == 48000 && format == AUDIO_S16SYS && channels == 2 && size == 4096);
    opens++;
    if (fail_open) return -1;
    opened = true; return 0;
}
static int Mix_AllocateChannels(int count) { assert(count == 1); return count; }
static int Mix_Volume(int channel, int value)
{ assert(opened && channel == 0); gain = value; return 0; }
static int Mix_PlayChannel(int channel, Mix_Chunk *chunk, int loops)
{ assert(opened && channel == 0 && chunk == &sample && loops == 0); plays++; playing = true; return 0; }
static int Mix_Playing(int channel)
{ assert(opened && channel == 0); polls++; return playing ? 1 : 0; }
static Uint32 SDL_GetTicks(void) { return now; }
static void SDL_Delay(Uint32 delay) { now += delay; }

#include "menu_audio.h"

int main(void)
{
    /* Unavailable startup audio is optional and never retries in the UI loop. */
    menu_audio_init(); menu_audio_play(0); menu_audio_idle(500);
    assert(loads == 0 && opens == 0 && polls == 0 && reads == 0);
    /* Invalid/missing theme data releases the device and stays silent. */
    opened = true; asset = NULL; menu_audio_init(); menu_audio_play(0);
    assert(closes == 1 && opens == 0 && !opened);
    opened = true; asset = &sample; menu_audio_init();
    assert(closes == 2 && loads == 2 && !opened);
    muted = true; menu_audio_play(0); assert(opens == 0);
    muted = false; settings.volume = 0; menu_audio_play(0); assert(opens == 0);
    settings.volume = 10; settings.bgm_volume = 0; menu_audio_play(0); assert(opens == 0);
    settings.bgm_volume = 10; fail_open = true; menu_audio_play(0);
    assert(opens == 1 && !opened && plays == 0);
    fail_open = false; menu_audio_play(10);
    assert(opened && opens == 2 && gain == 64 && plays == 1);
    settings.bgm_volume = 99; menu_audio_play(20);
    assert(opens == 2 && gain == 128 && plays == 2); /* reuse one channel */
    menu_audio_idle(269); assert(polls == 0);
    menu_audio_idle(270); assert(opened); /* don't truncate a playing cue */
    playing = false; menu_audio_idle(271); assert(!opened && closes == 3);
    unsigned idle_polls = polls;
    menu_audio_idle(1000); assert(polls == idle_polls); /* no idle mixer work */
    menu_audio_play(UINT32_MAX - 100); playing = false;
    menu_audio_idle(200); assert(!opened); /* SDL tick rollover */
    menu_audio_play(300); muted = true; menu_audio_play(301);
    assert(!opened && !playing); /* stop an old cue when mute changes */
    muted = false; menu_audio_play(400);
    now = UINT32_MAX - 50; Uint32 start = now;
    menu_audio_finish();
    assert((Uint32)(now - start) == 100 && !opened && menu_sound == NULL);
    unsigned previous_closes = closes;
    menu_audio_finish(); assert(closes == previous_closes); /* idempotent */
    puts("menu audio: mute/volume, absent asset/device, one-channel lifetime, idle and bounded exit passed");
    return 0;
}
