#ifndef KIDS_MENU_AUDIO_H
#define KIDS_MENU_AUDIO_H

/* Onion owns theme loading, settings and the decoded sample. This boundary
 * owns only the mixer device/channel. No work runs while it is idle/closed. */
static Mix_Chunk *menu_sound;
static bool menu_audio_open;
static Uint32 menu_audio_last_input;

static void menu_audio_close(void)
{
    if (!menu_audio_open)
        return;
    Mix_HaltChannel(0);
    Mix_CloseAudio();
    menu_audio_open = false;
}

static void menu_audio_init(void)
{
    /* SDL_InitDefault may fail to open audio; that must not break the kiosk. */
    if (Mix_QuerySpec(NULL, NULL, NULL) == 0)
        return;
    menu_audio_open = true;
    menu_sound = resource_getSoundChange();
    menu_audio_close();
}

static void menu_audio_play(Uint32 ticks)
{
    if (menu_sound == NULL)
        return;
    /* Read only on an input event, not in the idle render/timer loop. */
    _settings_load_mainui();
    int volume = settings.bgm_volume;
    if (settings.volume <= 0 || volume <= 0 || config_flag_get(".muteVolume")) {
        menu_audio_close();
        return;
    }
    if (!menu_audio_open) {
        if (Mix_OpenAudio(48000, AUDIO_S16SYS, 2, 4096) < 0)
            return;
        menu_audio_open = true;
        Mix_AllocateChannels(1);
    }
    if (volume > 20)
        volume = 20;
    Mix_Volume(0, volume * MIX_MAX_VOLUME / 20);
    /* A new navigation cue replaces the previous one; never queue/overlap. */
    Mix_PlayChannel(0, menu_sound, 0);
    menu_audio_last_input = ticks;
}

static void menu_audio_idle(Uint32 ticks)
{
    if (menu_audio_open && (Uint32)(ticks - menu_audio_last_input) >= 250 &&
        Mix_Playing(0) == 0)
        menu_audio_close();
}

static void menu_audio_finish(void)
{
    /* Let short confirm/back cues reach the speaker, but never let an unusual
     * theme sample delay game launch or shutdown for more than 100 ms. */
    Uint32 started = SDL_GetTicks();
    while (menu_audio_open && Mix_Playing(0) &&
           (Uint32)(SDL_GetTicks() - started) < 100)
        SDL_Delay(10);
    menu_audio_close();
    menu_sound = NULL; /* resources_free() releases the owned sample later. */
}

#endif
