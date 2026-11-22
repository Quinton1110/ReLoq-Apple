/*
 * ev_bridge.h - the one C interface the Swift side (app preview and the speech-provider extension)
 * speaks to. Everything above this line of the stack is engine-agnostic; everything below it is
 * either the STUB (this build) or the real engine, ReLoq C (Engine/Reloq-C, include/eci.h).
 *
 * ==================== THE ENGINE SEAM ====================
 * ev_bridge.c carries both implementations, chosen at compile time:
 *   - no ELOQUENCE_ENGINE define  -> the stub: a tone shaped by the same eight parameters the engine
 *     takes, so the plumbing (settings, prosody, sample rate, cancel, streaming) is testable
 *     without it;
 *   - -DELOQUENCE_ENGINE=1        -> the real engine through include/eci.h: ReLoq C
 *     (the Engine/Reloq-C submodule, -DEV_ENGINE_reloq=1; the engine since 2026-11-19, before it
 *     openevv). The notes below still say how openevv differed where that explains a choice.
 * Engine/README.md says what to drop where. Nothing in Swift changes when the engine goes in.
 * =========================================================
 *
 * Samples are 16-bit signed mono at `sample_rate` hertz (11025 is the engine's native rate; the
 * others the engine makes itself, see ev_sample_rate_supported). They stream through the callback
 * as they are made; the callback returns 0 to keep going or non-zero to stop (a cancel), exactly
 * as ClassicVoices' cv_pcm_fn does.
 */
#ifndef EV_BRIDGE_H
#define EV_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The rate Eloquence has always run at, and the default. */
#define EV_NATIVE_SAMPLE_RATE 11025

/* Which engine this build speaks with: "reloq" or "stub". Static storage. */
const char *ev_engine_name(void);

/* The engine's eight voice parameters, in its own units, in the engine's own order
   (include/eci.h ECIVoiceParam: eciGender = 0 ... eciVolume = 7). Every preset is a set of these
   and every request is spoken with a set of these. */
typedef struct ev_voice_params {
    int32_t gender;            /* 0 male, 1 female */
    int32_t head_size;         /* 0...100 */
    int32_t pitch_baseline;    /* 0...100 */
    int32_t pitch_fluctuation; /* 0...100  ("inflection", the pitch range) */
    int32_t roughness;         /* 0...100 */
    int32_t breathiness;       /* 0...100 */
    int32_t speed;             /* 0...250 */
    int32_t volume;            /* 0...100 */
} ev_voice_params;

#define EV_DIAL_MAX   100
#define EV_SPEED_MAX  250
#define EV_PRESETS    8

/* The speed every voice anchors at when VoiceOver's rate is at its default: six of the eight presets
   ship at 50 and Apple's Reed runs at 50 (openevv docs/notes/apple-eloquence.md). Glen and Sandy ship
   at 70, which is 1.5x - authentic Eloquence, but a voice must never change speed just because it was
   selected (a requirement from the start, 2026-09-22), so the SPEED DIAL starts at 50 for all eight and the
   preset's own value is only shown. */
#define EV_STANDARD_SPEED 50

/* Speed units for a request: `anchor` (the voice's speed dial) moved by the requested factor.
   MEASURED on the Mac build (`evv -s N`, one 15-word sentence, 2026-09-22): duration is about
   exponential in the units - 2.74x at 100, 5.9x at 140, 9x at 160, 21x at 250 (unintelligible) -
   so a factor is ADDITIVE in units: units = anchor + 49.6 x ln(factor), fitted from 0 to 160.
   VoiceOver's whole slider (1/3x ... 7.2x) therefore spans about units 0 ... 148; nothing above 160
   is ever asked for by the slider. */
int32_t ev_speed_units(int32_t anchor, double factor);

/* What one request asks for ON TOP of the voice's settings - VoiceOver's prosody. All relative,
   so 1.0 / 0 speak the voice exactly as its settings say. */
typedef struct ev_prosody {
    double speed;      /* x the voice's speed (SpeechRate.speedFactor: 1/3 ... 7.2) */
    double pitch_st;   /* semitones off the voice's pitch, in hertz (-12 ... 12; see ev_pitch_hz) */
    double range;      /* x the voice's pitch fluctuation (0.5 ... 2) */
    double volume;     /* x the voice's volume (0 ... 1) */
} ev_prosody;

typedef struct ev_request {
    ev_voice_params voice;   /* the eight, as set for this voice (preset or the user's own) */
    ev_prosody      prosody; /* what this utterance asks for on top */
    int32_t         sample_rate; /* hertz; see ev_sample_rate_supported */
} ev_request;

/* ==================== LANGUAGES ====================
 * By the engines' own language/dialect numbers. Each handle speaks one; each language has its own
 * community and user dictionary files (a "slot"). Which ones exist depends on the engine:
 *   ReLoq C (14): en-US en-GB es-ES es-MX fr-FR fr-CA de-DE it-IT zh-CN pt-BR ja-JP fi-FI ko-KR el-GR
 *     (its eci_languages less 0x60001: Taiwan Mandarin is the same module, NVDA lists it once). Text:
 *     Windows-1252 for the Latin-script ones, UTF-8 (eciAddTextUtf8) for Chinese, Japanese, Korean
 *     and Greek. No Polish.
 *   (openevv, the engine before ReLoq C, had ten, with Polish: pl-PL keeps its number here because its
 *     voices' slugs and dictionary folder are permanent.)
 *   the stub: all of them, so the Swift side can be tested with every voice. */
#define EV_LANG_ENUS 0x10000
#define EV_LANG_ENGB 0x10001
#define EV_LANG_ESES 0x20000
#define EV_LANG_ESUS 0x20001        /* Latin American Spanish (es-MX) */
#define EV_LANG_FRFR 0x30000
#define EV_LANG_FRCA 0x30001
#define EV_LANG_DEDE 0x40000
#define EV_LANG_ITIT 0x50000
#define EV_LANG_ZHCN 0x60000        /* ReLoq only */
#define EV_LANG_PTBR 0x70000        /* ReLoq only */
#define EV_LANG_JAJP 0x80000
#define EV_LANG_FIFI 0x90000        /* ReLoq only */
#define EV_LANG_KOKR 0xa0000        /* ReLoq only */
#define EV_LANG_PLPL 0x110000       /* not in ReLoq C (the stub only) */
#define EV_LANG_ELGR 0x120000       /* ReLoq only */
/* Room for every language any engine here has (dictionary slots); ev_lang_count() is this build's. */
#define EV_LANGS 16
/* 0 ... ev_lang_count()-1 for a language this build's engine speaks, -1 otherwise. */
int ev_lang_index(int32_t eci_lang);
int ev_lang_count(void);

/* An open voice: one engine instance set to one preset (or one stub state). Not reentrant: one
   utterance at a time per handle. EloquenceEngine.swift pools them. */
typedef struct ev_voice ev_voice;

/* return 0 to continue, non-zero to stop after this chunk */
typedef int (*ev_pcm_fn)(const int16_t *pcm, int n, void *user);

/* Which build this is: 1 = the real engine, 0 = the stub. */
int ev_engine_present(void);
/* "stub tone generator" or the engine's own eciVersion string. Static storage. */
const char *ev_engine_description(void);

/* The rates a caller may ask for.
   ReLoq C: exactly the seven ECI rate codes, 8000 11025 22050 16000 32000 44100 48000 (codes 0-6),
     each SYNTHESISED at that rate (its own Klatt renderer; reloq_eci.c sample_hz) - what Android's
     sample-rate setting has always offered.
   (openevv, the engine before, synthesised only 8000 and 11025 and resampled every rate above 11025.)
   The stub accepts ReLoq's seven. */
int ev_sample_rate_supported(int32_t hz);
/* 1 when the engine really synthesises at `hz` (not the 11025 voice resampled): what decides whether
   the app offers a sample-rate setting at all. */
int ev_sample_rate_native(int32_t hz);

/* preset = the engine's own voice number, 1...8. NULL on failure. */
ev_voice *ev_voice_open(int preset);                 /* US English */
ev_voice *ev_voice_open_lang(int preset, int32_t lang);
void ev_voice_close(ev_voice *v);

/* The preset's own eight (engine: eciGetVoiceParam(h, preset, i) for each; stub: the table copied
   from `evv -l` of the Mac build on 2026-09-22). Returns 0 ok, -1 error. */
int ev_voice_preset_params(ev_voice *v, ev_voice_params *out);

/* The preset's own name as the engine reports it (eciGetVoiceName), for checking the
   Reed...Grandpa mapping against the real thing. NUL-terminated, at most `room` bytes.
   Stub: "Stub voice N". */
void ev_voice_engine_name(ev_voice *v, char *out, int room);

/* The eight the engine will actually be told for a request: the voice's settings with the prosody
   applied and every value clamped to its range. Exposed so the app and the self-test can show it.
   Speed: MEASURED (ev_speed_units). Pitch: MEASURED (2026-09-24) - a semitone shift moves the voice's
   pitch in HERTZ by 2^(st/12) on the engine's own dial-to-hertz curve (ev_pitch_hz), limited to
   EV_PITCH_UP_MAX_ST up / EV_PITCH_DOWN_MAX_ST down and never pushed above EV_PITCH_CEILING by a
   request. Range (fluctuation x range) and volume (x volume) are still first guesses. */
void ev_apply_prosody(const ev_voice_params *voice, const ev_prosody *p, ev_voice_params *out);

/* The engine's pitch dial in hertz and back. The curve is the engine's OWN conversion: with
   eciRealWorldUnits on, eciGetVoiceParam(eciPitchBaseline) answers these hertz for dials 0, 5 ... 100
   (read from openevv on the Mac 2026-09-24, identical for every preset):
     40 41 42 44 46 49 53 57 63 70 78 89 102 118 139 164 196 236 285 346 422
   and the fundamental measured by autocorrelation in real renders follows it (median F0 5-7 % below
   the table from dial 40 up: 74 Hz at 50, 111 at 65, 184 at 80, 269 at 90, 394 at 100). Log-linear
   between the points. */
double ev_pitch_hz(double dial);
double ev_pitch_dial(double hz);

/* A request never raises the pitch more than this many semitones, or lowers it more than the other,
   and a raise never takes the dial above the ceiling (unless the voice's own dial is already higher).
   VoiceOver's pitch changes seen so far are -15 % (-2.8 st) and +30 % (+4.5 st). */
#define EV_PITCH_UP_MAX_ST    8.0
#define EV_PITCH_DOWN_MAX_ST 12.0
#define EV_PITCH_CEILING     95

/* ==================== THE COMMUNITY PRONUNCIATION DICTIONARY (opt-in) ====================
 * The three files of github.com/eigencrow/IBMTTSDictionaries (CC0): ENUmain.dic (whole words),
 * ENURoot.dic (word roots, also inflected: "iphone" covers "iPhones"), ENUabbr.dic (abbreviations).
 * Windows-1252 bytes, one "key TAB replacement" per line; a replacement is a respelling or a
 * `[...] phoneme annotation.
 *
 * Process-wide. ev_dict_configure takes the three paths (NULL or "" = that volume off; all three off =
 * no dictionary) and is cheap to call before every request: nothing happens unless a path changed.
 * Each voice handle picks the change up on its next utterance: its old set is dropped, a new one made.
 *
 * ⚠️ HOW (measured on the Mac with openevv, 2026-09-24): main (1,233 entries) and abbr (84) go into the
 * engine with eciLoadDict, 40 ms and 3 ms. The root file (68,414 entries) CANNOT: openevv's allocator
 * is a first-fit walk over every block (src/port/evv_arena.c), so eciLoadDict of that file took 39.6 s
 * and every render afterwards was ~45 % slower. So the root file is parsed HERE into a sorted table,
 * outside the engine, and before each utterance only the root entries for the words in that text
 * (and their plain stems: -s, -'s, -es, -ies, -ed, -ing, -er, -ly ...) are handed to the engine with
 * eciUpdateDict - a subset of what loading the whole file would have given. Every EV_DICT_ROOT_RESET
 * entries a handle's set is rebuilt so the engine's heap stays small. A path of 240 bytes or more is
 * refused (the engine copies a dictionary's name into 264 bytes). */
#define EV_DICT_ROOT_RESET 2000
int ev_dict_configure(const char *main_path, const char *root_path, const char *abbr_path);

/* ==================== UK ENGLISH AND THE US FILES ====================
 * No project publishes UK English community files (ENG*.dic), so the app hands UK English the US ones, and the
 * bridge adapts each entry for a UK voice (ev_bridge.c "ONE ENGLISH DICTIONARY FOR BOTH DIALECTS"): an entry whose
 * `[...] phonemes use the flap F or the glottal stop ? is left out (the UK engine cannot say them and would read a
 * whole-word entry out as text), an unstressed R becomes the schwa x, and everything else goes in unchanged. The
 * main and abbreviation files are adapted into copies in the process's temporary folder, which a UK handle loads
 * with eciLoadDict (fast) instead of the US files. No other language,
 * US English included, is touched. ev_dict_adapt_value is that rule for one replacement: 1 = keep (out holds it,
 * adapted), 0 = left out, -1 = bad arguments or out too small. */
int ev_dict_adapt_value(int32_t lang, const char *in, char *out, int room);

/* How many "key TAB replacement" entries a dictionary file holds, as this bridge parses it (the app's
   validation of a download). -1 unreadable. */
int ev_dict_count_entries(const char *path);

/* The root table in force: its entry count (0 = none). */
int ev_dict_root_entries(void);

/* ==================== THE USER'S OWN ENTRIES ====================
 * Three files in the same "key TAB replacement" format (Windows-1252), written by the app's dictionary
 * editor into <group>/Library/UserDictionary/ - a folder of their own that the community download,
 * "Update now" and the clean-up of old releases never touch. Configured separately from the community
 * files and ALWAYS in force when present, whether or not "Use community dictionary" is on: they are
 * the user's own list.
 *
 * They WIN over the community files: whole words and abbreviations go into the engine with
 * eciUpdateDict after the community files are loaded (an update over a loaded key replaces it -
 * measured on the Mac 2026-09-24); a root entry is looked up in the user's table before the community
 * one. Case follows the engine: whole words and abbreviations match exactly, roots in any case. One
 * addition for whole words: a word written in a capitalisation the engine has no entry for falls back
 * to the user's entry in any capitalisation ("hello" also covers "Hello" at the start of a sentence),
 * before the community file's several-capitalisation words (288d9f0).
 *
 * Cheap to call before every request: each file is stat()ed and re-read only when its size,
 * modification time or inode changed (the app writes atomically), so an edit reaches the next
 * utterance. NULL or "" = no file for that volume. */
int ev_dict_configure_user(const char *main_path, const char *root_path, const char *abbr_path);
/* The same for any language (the unsuffixed ones are US English). */
int ev_dict_configure_lang(int32_t lang, const char *main_path, const char *root_path, const char *abbr_path);
int ev_dict_configure_user_lang(int32_t lang, const char *main_path, const char *root_path, const char *abbr_path);
int ev_dict_user_entries_lang(int32_t lang);

/* For the dictionary editor's Listen through VoiceOver: until changed, `skip_word` (any case; NULL or
   "" = none) is left out of the user's entries for this language, and with `community_off` the
   community files are too - so the extension can say a word as it is WITHOUT an entry. The extension
   sets it per request (PronunciationDictionary.configureEngine), so it lasts one utterance. */
int ev_dict_set_listen(int32_t lang, const char *skip_word, int community_off);

/* How many user entries are in force (main + root + abbr, after duplicates). */
int ev_dict_user_entries(void);

/* "Enable backquote voice tags", process-wide, default OFF (NVDA's IBMTTS driver: same name, same
   default). OFF: every backtick in the text becomes a space before the engine sees it, so a stray one
   in a message can neither change the voice nor be read out; the engine's eciInputType stays 0. ON: the
   text goes through with eciInputType 1 and the engine obeys its annotations (`vv volume, `pp pitch,
   `[..] phonemes, `ts text mode...); a `ts left over from one utterance is reset before the next.
   Dictionary entries (including phoneme pronunciations) go through the dictionary API, not the text,
   and work either way. */
void ev_set_voice_tags(int on);
int ev_voice_tags(void);

/* "Phrase prediction", process-wide, default ON (IBM's engine and our openevv fork both start with it on;
   upstream openevv turned it off by default on 2026-10-06, 3352370; ReLoq C also starts with it off). The
   engine's environment parameter 11: in a long stretch with no punctuation it guesses where a phrase ends
   and pauses there, and it lets two rules decide a comma is not a break. Off: no guessed pauses, and every
   comma pauses.
   HOW, ReLoq C: an ordinary per-instance parameter (RELOQ_ECI_PHRASE_PREDICTION = 11); set with eciSetParam
   on the handle whenever it differs from what the handle has. (ReLoq REFUSES eciSetDefaultParam(11, ...).)
   HOW, openevv (src/eci/api): eciSetParam(h, 11, ...) is REFUSED on an instance (ev_setParam
   answers -1 for 11, as IBM's does), so the value goes in with eciSetDefaultParam(11, ...) just before
   eciNewEx - a new instance copies the defaults (eo_getDefaultEnvironment) - and a pooled handle made
   with the other value is remade at its next utterance (its dictionary set is rebuilt with it). The `pp
   annotation is not used: with voice tags off there are no annotations. The stub ignores it. */
void ev_set_phrase_prediction(int on);
int ev_phrase_prediction(void);

/* ReLoq C's tone controls, process-wide: the output equaliser's three bands in dB, -12..+12 (0 = flat; bass a
   low shelf at 250 Hz, midrange a bell at 1200 Hz, treble a high shelf at 3000 Hz; RELOQ_ECI_EQ_LOW/MID/HIGH)
   and Mellow mode (RELOQ_ECI_MELLOW_MODE: less presence, from 16 kHz up). Defaults 0, 0, 0 and off - ReLoq's
   own, so with them the engine is never told anything: a handle is set only when a value differs from what it
   has, before an utterance (the next utterance of any synthesizer hears a change). The app hands them over in
   configureEngine() before every request. Values outside -12..+12 are clamped. ev_tone_available() is 0 with
   the openevv engine, which has no such parameters (and the calls do nothing there). */
void ev_set_tone(int bass_db, int mid_db, int treble_db, int mellow);
void ev_tone(int *bass_db, int *mid_db, int *treble_db, int *mellow);
int ev_tone_available(void);

/* ReLoq C's "Shorten pauses" (RELOQ_ECI_PAUSE_MODE), process-wide: 0 = the original pauses (ReLoq's default),
   1 = only the final automatic pause of the text is shortened, 2 = every automatic pause is. Pauses the text
   asks for explicitly keep their length. Handled like the tone controls: the app hands it over in
   configureEngine() before every request, and a handle is told only when the value differs from what it has
   (at the default, never). Values outside 0..2 are clamped. */
void ev_set_pause_mode(int mode);
int ev_pause_mode(void);
int ev_pause_mode_available(void);

/* openevv's US English text pre-pass (Shared/Bridge/ev_marks.inc), which ReLoq C is handed text through:
   on by default; off only for comparisons on the Mac. (The openevv engine did it itself.) */
void ev_set_text_prepass(int on);

/* The text as the engine is handed it (the UTF-8 to bytes fold, format characters dropped, backticks
   neutralised unless voice tags are on, and for US English on ReLoq the pre-pass), for the Mac tests.
   Returns its length, -1 on error. */
int ev_text_fold(const char *utf8, char *out, int room);
int ev_text_fold_lang(const char *utf8, int32_t lang, char *out, int room);

/* What a handle's dictionary did on its last utterance, for the log (no words): whether a set is in
   force, the eciLoadDict answers for main and abbr (-1 = not loaded), root entries handed over so far. */
typedef struct ev_dict_report {
    int32_t in_force;
    int32_t main_rc;
    int32_t abbr_rc;
    int32_t root_added;
    int32_t user_added;     /* the user's own whole-word and abbreviation entries the engine took */
} ev_dict_report;
void ev_voice_dict_report(ev_voice *v, ev_dict_report *out);

/* Why the engine refused the handle's last utterance, when it did (rc -1): ReLoq C's RELOQ_ECI_LAST_ERROR
   (-2 unsupported text, -6 render, -7 memory ...) and RELOQ_ECI_FAILURE_STAGE (2 text, 3 acoustic), for
   the status line - no words. 0, 0 when it did not fail, and always with openevv and the stub. */
void ev_voice_engine_error(ev_voice *v, int *code, int *stage);

/* After an utterance that was STOPPED (ev_voice_speak returned 1): brings the handle back to the state
   its next utterance starts fastest from. ReLoq C prepares an instance for its next request at the end
   of every request that COMPLETES, so after a stop the next request first pays a full reset: measured on
   the Mac, its first sound 10.6 ms after the request instead of 0.2 (openevv: 16-17 ms either way).
   This speaks one letter into nothing (~11.6 ms, on the caller's thread) so that the reset happens
   now, off the path of the next request: that one then starts in 0.3 ms. The pool calls it on the
   engine thread before the handle goes back. openevv and the stub: nothing to do. */
void ev_voice_prime(ev_voice *v);

/* How fast the voice REALLY speaks at a requested factor: the factor the clamped units come to on
   the measured curve (the dial stops at 0 and 250). The pauses between segments scale with this. */
double ev_effective_speed(const ev_voice_params *voice, double factor);

/* Speaks `text` (plain UTF-8, no markup - SSML is handled in Swift), streaming Int16 PCM at
   req->sample_rate to `cb` as it is produced. Blocks until the utterance is finished or stopped.
   Nothing is spoken for text with no letters or digits. Returns 0 done, 1 stopped by the callback,
   -1 error. */
int ev_voice_speak(ev_voice *v, const char *text, const ev_request *req, ev_pcm_fn cb, void *user);

#ifdef __cplusplus
}
#endif

#endif
