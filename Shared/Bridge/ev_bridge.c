/*
 * ev_bridge.c - the C layer between Swift and the speech engine. Two implementations of the same
 * ev_bridge.h interface live here, one compiled at a time:
 *
 *   #if ELOQUENCE_ENGINE   the real engine (ReLoq C) through its published interface,
 *                          include/eci.h. See "THE ENGINE SEAM" below and Engine/README.md.
 *   #else                  the STUB: a tone shaped by the same eight voice parameters, the same
 *                          prosody and the same sample rate the engine takes, so every piece of
 *                          plumbing is exercised and its effect can be measured in the audio.
 *
 * Both share the parameter mapping (ev_apply_prosody) and the range checks, so the numbers the
 * engine is eventually told are the numbers the stub was shaped by.
 *
 * Privacy: this is a screen-reader voice. Nothing here logs or stores the text it speaks.
 */

#include "ev_bridge.h"

/* The real-engine half speaks to ReLoq C (ev_bridge.h "THE ENGINE SEAM"). The openevv half this file
   also had until 2026-11-19 is not in this repository. */
#define EV_RELOQ 1

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ======================================================================
 * Shared: parameter mapping, ranges
 * ====================================================================== */

static int32_t ev_clamp(double v, int32_t lo, int32_t hi)
{
    if (!(v == v)) return lo;                      /* NaN */
    if (v < lo) return lo;
    if (v > hi) return hi;
    return (int32_t)floor(v + 0.5);
}

/* The ECI sample-rate codes 0-6 in hertz (IBM's order; ReLoq's sample_hz, openevv's ev_rateByCode). */
static const int32_t ev_rate_by_code[7] = { 8000, 11025, 22050, 16000, 32000, 44100, 48000 };

static int ev_rate_code(int32_t hz) __attribute__((unused));   /* openevv takes hertz */
static int ev_rate_code(int32_t hz)
{
    int i;
    for (i = 0; i < 7; i++) if (ev_rate_by_code[i] == hz) return i;
    return -1;
}

int ev_sample_rate_supported(int32_t hz)
{
    /* ReLoq C (and the stub): the seven rate codes; eciSetParam(eciSampleRate) refuses anything else. */
    return ev_rate_code(hz) >= 0;
}

int ev_sample_rate_native(int32_t hz)
{
    return ev_rate_code(hz) >= 0;
}

/* ReLoq C has the tone controls (ev_set_tone); openevv has none. The stub answers yes, so the tests and a
   stub build of the app see the controls. */
int ev_tone_available(void)
{
    return 1;
}

/* ReLoq C has "Shorten pauses" (ev_set_pause_mode); the stub answers yes, as for the tone controls. */
int ev_pause_mode_available(void)
{
    return 1;
}

/* Speed units per e-fold of speed, from the measurement in ev_bridge.h:
     units:    0     10    20    30    40    50    60    70    80   100   120   140   160   200   250
     factor: 0.37  0.45  0.55  0.67  0.82  1.00  1.23  1.50  1.83  2.74  4.01  5.90  9.03  16.8  21.6
   ln(2.74) / 50 = 0.0202 per unit -> 49.6 units per e-fold; the fit holds within ~7 % to 160 and the
   engine saturates above 200. */
#define EV_SPEED_UNITS_PER_EFOLD 49.6

int32_t ev_speed_units(int32_t anchor, double factor)
{
    if (!(factor > 0)) factor = 1.0;
    return ev_clamp(anchor + EV_SPEED_UNITS_PER_EFOLD * log(factor), 0, EV_SPEED_MAX);
}

/* eciPitchBaseline 0, 5 ... 100 in hertz, as the engine itself converts them (eciRealWorldUnits). */
static const double ev_pitch_table[21] = {
    40, 41, 42, 44, 46, 49, 53, 57, 63, 70, 78, 89, 102, 118, 139, 164, 196, 236, 285, 346, 422
};

double ev_pitch_hz(double dial)
{
    int i;
    double f;
    if (!(dial == dial)) dial = 0;
    if (dial <= 0) return ev_pitch_table[0];
    if (dial >= 100) return ev_pitch_table[20];
    i = (int)(dial / 5.0);
    if (i > 19) i = 19;
    f = (dial - 5.0 * i) / 5.0;
    return exp(log(ev_pitch_table[i]) + f * (log(ev_pitch_table[i + 1]) - log(ev_pitch_table[i])));
}

double ev_pitch_dial(double hz)
{
    int i;
    double lh;
    if (!(hz == hz) || hz <= ev_pitch_table[0]) return 0;
    if (hz >= ev_pitch_table[20]) return 100;
    lh = log(hz);
    for (i = 0; i < 20; i++) {
        double a = log(ev_pitch_table[i]), b = log(ev_pitch_table[i + 1]);
        if (lh <= b) return 5.0 * i + 5.0 * (lh - a) / (b - a);
    }
    return 100;
}

/* The voice's dial moved by `st` semitones in hertz, within the limits in ev_bridge.h. */
static int32_t ev_pitch_shift(int32_t dial, double st)
{
    double target;
    int32_t out;
    if (!(st == st) || st == 0) return dial;
    if (st > EV_PITCH_UP_MAX_ST) st = EV_PITCH_UP_MAX_ST;
    if (st < -EV_PITCH_DOWN_MAX_ST) st = -EV_PITCH_DOWN_MAX_ST;
    target = ev_pitch_dial(ev_pitch_hz(dial) * pow(2.0, st / 12.0));
    out = ev_clamp(target, 0, EV_DIAL_MAX);
    if (st > 0) {
        int32_t ceiling = dial > EV_PITCH_CEILING ? dial : EV_PITCH_CEILING;
        if (out > ceiling) out = ceiling;
        if (out < dial) out = dial;
    } else if (out > dial) {
        out = dial;
    }
    return out;
}

void ev_apply_prosody(const ev_voice_params *voice, const ev_prosody *p, ev_voice_params *out)
{
    ev_prosody pr = { 1.0, 0.0, 1.0, 1.0 };
    if (p) pr = *p;
    if (!(pr.speed > 0)) pr.speed = 1.0;
    if (!(pr.range > 0)) pr.range = 1.0;
    if (!(pr.volume >= 0)) pr.volume = 1.0;
    if (!(pr.pitch_st == pr.pitch_st)) pr.pitch_st = 0;

    out->gender            = ev_clamp(voice->gender, 0, 1);
    out->head_size         = ev_clamp(voice->head_size, 0, EV_DIAL_MAX);
    /* Pitch: MEASURED (ev_pitch_hz). The old mapping multiplied the DIAL by 2^(st/12), but the dial is
       exponential in hertz (about 0.63 semitones per unit above 60), so +20 % on Shelley's 81 came to
       dial 97 = +10 semitones, and anything bigger pinned the dial at 100 - the "typed text jumps all
       the way up" that was heard. Now the shift is applied in hertz on the engine's own curve.
       ⚠️ Range and volume: still first guesses (proportional in the engine's units). */
    out->pitch_baseline    = ev_pitch_shift(ev_clamp(voice->pitch_baseline, 0, EV_DIAL_MAX), pr.pitch_st);
    out->pitch_fluctuation = ev_clamp(voice->pitch_fluctuation * pr.range, 0, EV_DIAL_MAX);
    out->roughness         = ev_clamp(voice->roughness, 0, EV_DIAL_MAX);
    out->breathiness       = ev_clamp(voice->breathiness, 0, EV_DIAL_MAX);
    out->speed             = ev_speed_units(ev_clamp(voice->speed, 0, EV_SPEED_MAX), pr.speed);
    out->volume            = ev_clamp(voice->volume * pr.volume, 0, EV_DIAL_MAX);
}

double ev_effective_speed(const ev_voice_params *voice, double factor)
{
    int32_t anchor = ev_clamp(voice ? voice->speed : EV_STANDARD_SPEED, 0, EV_SPEED_MAX);
    int32_t units = ev_speed_units(anchor, factor);
    return exp((units - anchor) / EV_SPEED_UNITS_PER_EFOLD);
}

/* Does the text carry anything to say? (Never inject sample text for an empty request: DECtalk
   shipped "This is DECtalk" all over VoiceOver.) Counts letters and digits, ASCII or not. */
static int ev_speakable_chars(const char *text)
{
    int n = 0;
    const unsigned char *p = (const unsigned char *)text;
    if (!p) return 0;
    for (; *p; p++) {
        if ((*p >= '0' && *p <= '9') || (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || *p >= 0xC0)
            n++;
    }
    return n;
}

/* ======================================================================
 * Shared: the community dictionary's files and the root table (see ev_bridge.h)
 * ====================================================================== */

#include <pthread.h>
#include <errno.h>

typedef struct { const char *key; const char *val; int line; } ev_dict_pair;
typedef struct { char *buf; ev_dict_pair *pairs; int n; } ev_dict_table;

/* Splits a whole file (in `buf`, NUL-terminated, modified in place) into key/replacement pairs. Lines
   end at \n or \r; the key is everything before the first tab, trimmed; the replacement everything
   after the tabs, trimmed. Lines without a tab or with an empty half are skipped. `pairs` may be NULL
   to count only. */
static int ev_dict_split(char *buf, ev_dict_pair *pairs)
{
    int n = 0, line = 0;
    char *p = buf;
    while (*p) {
        char *start = p, *end, *tab, *k0, *k1, *v0, *v1;
        while (*p && *p != '\n' && *p != '\r') p++;
        end = p;
        while (*p == '\n' || *p == '\r') p++;
        line++;
        tab = memchr(start, '\t', (size_t)(end - start));
        if (!tab) continue;
        k0 = start; k1 = tab;
        while (k0 < k1 && (*k0 == ' ' || *k0 == '\t')) k0++;
        while (k1 > k0 && (k1[-1] == ' ' || k1[-1] == '\t')) k1--;
        v0 = tab; v1 = end;
        while (v0 < v1 && (*v0 == ' ' || *v0 == '\t')) v0++;
        while (v1 > v0 && (v1[-1] == ' ' || v1[-1] == '\t')) v1--;
        if (k0 == k1 || v0 == v1) continue;
        if (pairs) {
            *k1 = 0;
            *v1 = 0;
            pairs[n].key = k0;
            pairs[n].val = v0;
            pairs[n].line = line;
        }
        n++;
    }
    return n;
}

static char *ev_read_file(const char *path, long *size)
{
    FILE *f;
    long n;
    char *buf;
    if (!path || !*path) return NULL;
    f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0 || n > 64L * 1024 * 1024) {
        fclose(f);
        return NULL;
    }
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    buf[n] = 0;
    fclose(f);
    if (size) *size = n;
    return buf;
}

int ev_dict_count_entries(const char *path)
{
    long size = 0;
    char *buf = ev_read_file(path, &size);
    int n;
    if (!buf) return -1;
    /* a NUL inside means this is not a text dictionary */
    n = (long)strlen(buf) == size ? ev_dict_split(buf, NULL) : 0;
    free(buf);
    return n;
}

static unsigned char ev_lower(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return (unsigned char)(c + 32);
    if (c >= 0xC0 && c <= 0xDE && c != 0xD7) return (unsigned char)(c + 32);   /* Latin-1 / cp1252 capitals */
    return c;
}

static int ev_pair_cmp(const void *a, const void *b)
{
    const ev_dict_pair *x = (const ev_dict_pair *)a, *y = (const ev_dict_pair *)b;
    int c = strcmp(x->key, y->key);
    return c ? c : (x->line - y->line);
}

static void ev_dict_table_free(ev_dict_table *t)
{
    if (!t) return;
    free(t->pairs);
    free(t->buf);
    free(t);
}

/* How a table's keys are kept. */
#define EV_KEYS_LOWER     0   /* lower-cased (the root file: the engine matches roots in any case) */
#define EV_KEYS_MULTICASE 1   /* lower-cased, and only keys the file lists in several capitalisations */
#define EV_KEYS_EXACT     2   /* as written (main and abbreviations: the engine matches them exactly) */

/* A dictionary file as a sorted table; of two entries with one key the later line wins, as it does in
   the engine's own table (hashInsertString puts the later one first). */
static ev_dict_table *ev_dict_table_load(const char *path, int keys)
{
    const int multicase_only = keys == EV_KEYS_MULTICASE;
    ev_dict_table *t;
    int n, i, o;
    long size = 0;
    char *buf = ev_read_file(path, &size);
    if (!buf) return NULL;
    if ((long)strlen(buf) != size) { free(buf); return NULL; }
    t = (ev_dict_table *)calloc(1, sizeof *t);
    if (!t) { free(buf); return NULL; }
    t->buf = buf;
    {
        /* count on a copy: the split writes NULs */
        char *copy = (char *)malloc((size_t)size + 1);
        if (!copy) { ev_dict_table_free(t); return NULL; }
        memcpy(copy, buf, (size_t)size + 1);
        n = ev_dict_split(copy, NULL);
        free(copy);
    }
    if (n <= 0) { ev_dict_table_free(t); return NULL; }
    t->pairs = (ev_dict_pair *)malloc(sizeof(ev_dict_pair) * (size_t)n);
    if (!t->pairs) { ev_dict_table_free(t); return NULL; }
    n = ev_dict_split(buf, t->pairs);
    for (i = 0; keys != EV_KEYS_EXACT && i < n; i++) {
        unsigned char *k = (unsigned char *)t->pairs[i].key;
        for (; *k; k++) *k = ev_lower(*k);
    }
    qsort(t->pairs, (size_t)n, sizeof(ev_dict_pair), ev_pair_cmp);
    for (i = 0, o = 0; i < n; i++) {
        /* multicase_only: keep a key only when the file lists it in more than one spelling (as it does
           "ios", "IOS" and "Ios"), i.e. the authors meant it for every capitalisation */
        if (multicase_only) {
            int first = i, last = i;
            while (first > 0 && strcmp(t->pairs[first - 1].key, t->pairs[i].key) == 0) first--;
            while (last + 1 < n && strcmp(t->pairs[last + 1].key, t->pairs[i].key) == 0) last++;
            if (first == last) continue;
        }
        if (i + 1 < n && strcmp(t->pairs[i].key, t->pairs[i + 1].key) == 0) continue;   /* keep the last */
        t->pairs[o++] = t->pairs[i];
    }
    t->n = o;
    return t;
}

static const char *ev_dict_table_find(const ev_dict_table *t, const char *key)
{
    int lo = 0, hi;
    if (!t) return NULL;
    hi = t->n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2, c = strcmp(t->pairs[mid].key, key);
        if (c == 0) return t->pairs[mid].val;
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}

#define EV_DICT_PATH_MAX 240
static pthread_mutex_t ev_dict_lock = PTHREAD_MUTEX_INITIALIZER;
static int  ev_dict_gen = 0;                 /* bumped whenever any configuration changes */

/* One language's dictionaries (ev_bridge.h "LANGUAGES"). Every function below reaches the fields of
   `ev_cur`, the slot of the language in hand, which is only chosen and only read with ev_dict_lock
   held; the names are kept from when there was one language. */
typedef struct ev_dict_slot {
    char path[3][1024];                       /* community main, root, abbr; "" = off */
    ev_dict_table *root_table;
    ev_dict_table *main_ci_table;             /* main-file words listed in several capitalisations */
    char user_path[3][1024];                  /* the user's own main, root, abbr; "" = none */
    long long user_sig[3];                    /* size ^ mtime ^ inode when last read */
    ev_dict_table *user_main;                 /* exact keys: what goes into the engine */
    ev_dict_table *user_main_ci;              /* the same, lower-cased: for other capitalisations */
    ev_dict_table *user_root;                 /* lower-cased, like the community root table */
    ev_dict_table *user_abbr;                 /* exact keys */
    char skip[128];                           /* a word left out for one utterance (Listen); "" = none */
    int  community_off;                       /* the community files left out for one utterance */
} ev_dict_slot;

/* This build's languages (ev_bridge.h "LANGUAGES"); US English first, always. */
static const int32_t ev_lang_ids[] = {
#if   ELOQUENCE_ENGINE
    /* ReLoq C's fourteen (eci_languages less Taiwan Mandarin, which is the same module) */
    0x10000, 0x10001, 0x20000, 0x20001, 0x30000, 0x30001, 0x40000, 0x50000,
    0x60000, 0x70000, 0x80000, 0x90000, 0xa0000, 0x120000,
#else
    /* the stub: every language either engine has */
    0x10000, 0x10001, 0x20000, 0x20001, 0x30000, 0x30001, 0x40000, 0x50000,
    0x60000, 0x70000, 0x80000, 0x90000, 0xa0000, 0x110000, 0x120000,
#endif
};
#define EV_LANG_COUNT ((int)(sizeof ev_lang_ids / sizeof ev_lang_ids[0]))
typedef char ev_lang_room_check[EV_LANG_COUNT <= EV_LANGS ? 1 : -1];
static ev_dict_slot ev_slots[EV_LANGS];
static ev_dict_slot *ev_cur = &ev_slots[0];

int ev_lang_index(int32_t eci_lang)
{
    int i;
    for (i = 0; i < EV_LANG_COUNT; i++) if (ev_lang_ids[i] == eci_lang) return i;
    return -1;
}

int ev_lang_count(void) { return EV_LANG_COUNT; }

static ev_dict_slot *ev_slot(int32_t eci_lang)
{
    int i = ev_lang_index(eci_lang);
    return i < 0 ? NULL : &ev_slots[i];
}

#define ev_dict_path      (ev_cur->path)
#define ev_root_table     (ev_cur->root_table)
#define ev_main_ci_table  (ev_cur->main_ci_table)
#define ev_user_path      (ev_cur->user_path)
#define ev_user_sig       (ev_cur->user_sig)
#define ev_user_main      (ev_cur->user_main)
#define ev_user_main_ci   (ev_cur->user_main_ci)
#define ev_user_root      (ev_cur->user_root)
#define ev_user_abbr      (ev_cur->user_abbr)

int ev_dict_configure(const char *main_path, const char *root_path, const char *abbr_path)
{
    return ev_dict_configure_lang(EV_LANG_ENUS, main_path, root_path, abbr_path);
}

int ev_dict_configure_lang(int32_t lang, const char *main_path, const char *root_path, const char *abbr_path)
{
    const char *want[3];
    int i, changed = 0;
    ev_dict_slot *slot = ev_slot(lang);
    if (!slot) return -1;
    want[0] = main_path ? main_path : "";
    want[1] = root_path ? root_path : "";
    want[2] = abbr_path ? abbr_path : "";
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = slot;
    for (i = 0; i < 3; i++) {
        /* the engine copies a dictionary's name into 264 bytes (src/eci/dict/eci_usrdct.c): a longer
           path would overrun it, so it is refused here */
        if (strlen(want[i]) >= EV_DICT_PATH_MAX) want[i] = "";
        if (strcmp(ev_dict_path[i], want[i]) != 0) changed |= 1 << i;
    }
    if (changed) {
        for (i = 0; i < 3; i++) {
            strncpy(ev_dict_path[i], want[i], sizeof ev_dict_path[i] - 1);
            ev_dict_path[i][sizeof ev_dict_path[i] - 1] = 0;
        }
        if (changed & 2) {
            ev_dict_table_free(ev_root_table);
            ev_root_table = ev_dict_path[1][0] ? ev_dict_table_load(ev_dict_path[1], EV_KEYS_LOWER) : NULL;
        }
        if (changed & 1) {
            ev_dict_table_free(ev_main_ci_table);
            ev_main_ci_table = ev_dict_path[0][0] ? ev_dict_table_load(ev_dict_path[0], EV_KEYS_MULTICASE) : NULL;
        }
        ev_dict_gen++;
    }
    pthread_mutex_unlock(&ev_dict_lock);
    return 0;
}

/* ---- the user's own entries (ev_bridge.h "THE USER'S OWN ENTRIES") ---- */

#include <sys/stat.h>

static int sig_ok(long long sig) { return sig != -1; }

static long long ev_file_sig(const char *path)
{
    struct stat st;
    if (!path[0] || stat(path, &st) != 0) return -1;
#if defined(__APPLE__)
    return (long long)st.st_size * 1000003LL ^ ((long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec)
           ^ (long long)st.st_ino * 7919LL;
#else
    return (long long)st.st_size * 1000003LL ^ ((long long)st.st_mtim.tv_sec * 1000000000LL + st.st_mtim.tv_nsec)
           ^ (long long)st.st_ino * 7919LL;
#endif
}

int ev_dict_configure_user(const char *main_path, const char *root_path, const char *abbr_path)
{
    return ev_dict_configure_user_lang(EV_LANG_ENUS, main_path, root_path, abbr_path);
}

int ev_dict_configure_user_lang(int32_t lang, const char *main_path, const char *root_path, const char *abbr_path)
{
    const char *want[3];
    int i, changed = 0;
    ev_dict_slot *slot = ev_slot(lang);
    if (!slot) return -1;
    want[0] = main_path ? main_path : "";
    want[1] = root_path ? root_path : "";
    want[2] = abbr_path ? abbr_path : "";
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = slot;
    for (i = 0; i < 3; i++) {
        long long sig;
        if (strlen(want[i]) >= sizeof ev_user_path[i]) want[i] = "";
        sig = ev_file_sig(want[i]);
        if (strcmp(ev_user_path[i], want[i]) != 0 || sig != ev_user_sig[i]) {
            changed |= 1 << i;
            strncpy(ev_user_path[i], want[i], sizeof ev_user_path[i] - 1);
            ev_user_path[i][sizeof ev_user_path[i] - 1] = 0;
            ev_user_sig[i] = sig;
        }
    }
    if (changed & 1) {
        ev_dict_table_free(ev_user_main);
        ev_dict_table_free(ev_user_main_ci);
        ev_user_main = sig_ok(ev_user_sig[0]) ? ev_dict_table_load(ev_user_path[0], EV_KEYS_EXACT) : NULL;
        ev_user_main_ci = sig_ok(ev_user_sig[0]) ? ev_dict_table_load(ev_user_path[0], EV_KEYS_LOWER) : NULL;
    }
    if (changed & 2) {
        ev_dict_table_free(ev_user_root);
        ev_user_root = sig_ok(ev_user_sig[1]) ? ev_dict_table_load(ev_user_path[1], EV_KEYS_LOWER) : NULL;
    }
    if (changed & 4) {
        ev_dict_table_free(ev_user_abbr);
        ev_user_abbr = sig_ok(ev_user_sig[2]) ? ev_dict_table_load(ev_user_path[2], EV_KEYS_EXACT) : NULL;
    }
    if (changed) ev_dict_gen++;
    pthread_mutex_unlock(&ev_dict_lock);
    return 0;
}

int ev_dict_user_entries(void) { return ev_dict_user_entries_lang(EV_LANG_ENUS); }

int ev_dict_user_entries_lang(int32_t lang)
{
    int n;
    ev_dict_slot *slot = ev_slot(lang);
    if (!slot) return 0;
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = slot;
    n = (ev_user_main ? ev_user_main->n : 0) + (ev_user_root ? ev_user_root->n : 0) + (ev_user_abbr ? ev_user_abbr->n : 0);
    pthread_mutex_unlock(&ev_dict_lock);
    return n;
}

/* Whether `key` (lower-cased) is the word left out for one utterance. Lock held. */
static int ev_skipped(const char *key)
{
    size_t i;
    if (!ev_cur->skip[0]) return 0;
    for (i = 0; ev_cur->skip[i] && key[i]; i++)
        if (ev_lower((unsigned char)ev_cur->skip[i]) != (unsigned char)key[i]) return 0;
    return ev_cur->skip[i] == 0 && key[i] == 0;
}

/* A root key's reading: the user's own entry first, then the community file's. Lock held. */
static const char *ev_root_value(const char *key)
{
    const char *v = ev_skipped(key) ? NULL : ev_dict_table_find(ev_user_root, key);
    if (v) return v;
    return ev_cur->community_off ? NULL : ev_dict_table_find(ev_root_table, key);
}

int ev_dict_set_listen(int32_t lang, const char *skip_word, int community_off)
{
    ev_dict_slot *slot = ev_slot(lang);
    char want[128];
    if (!slot) return -1;
    snprintf(want, sizeof want, "%s", skip_word ? skip_word : "");
    pthread_mutex_lock(&ev_dict_lock);
    if (strcmp(slot->skip, want) != 0 || slot->community_off != (community_off ? 1 : 0)) {
        strcpy(slot->skip, want);
        slot->community_off = community_off ? 1 : 0;
        ev_dict_gen++;
    }
    pthread_mutex_unlock(&ev_dict_lock);
    return 0;
}

int ev_dict_root_entries(void)
{
    int n;
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = &ev_slots[0];
    n = ev_root_table ? ev_root_table->n : 0;
    pthread_mutex_unlock(&ev_dict_lock);
    return n;
}

/* The root keys worth looking up for one word (already lower-cased): the word and its plain stems.
   Calls `fn` for each; stops early when it answers non-zero. */
static void ev_word_candidates(const char *w, int (*fn)(const char *key, void *user), void *user)
{
    static const struct { const char *suffix; const char *add; } rules[] = {
        { "'s", "" }, { "s'", "" }, { "ies", "y" }, { "es", "" }, { "s", "" }, { "ied", "y" },
        { "ed", "" }, { "ed", "e" }, { "ing", "" }, { "ing", "e" }, { "ers", "" }, { "er", "" },
        { "est", "" }, { "ly", "" },
    };
    char buf[128];
    size_t n = strlen(w), i;
    if (n == 0 || n >= sizeof buf) return;
    if (fn(w, user)) return;
    for (i = 0; i < sizeof rules / sizeof rules[0]; i++) {
        size_t sl = strlen(rules[i].suffix), al = strlen(rules[i].add);
        if (n <= sl + 1 || strcmp(w + n - sl, rules[i].suffix) != 0) continue;
        memcpy(buf, w, n - sl);
        memcpy(buf + n - sl, rules[i].add, al + 1);
        fn(buf, user);
    }
}

/* Every word of `text` (bytes, as the engine gets them): runs of letters, with apostrophes inside. */
static void ev_each_word(const char *text, int (*fn)(const char *key, void *user), void *user)
{
    const unsigned char *p = (const unsigned char *)text;
    char w[128];
    while (*p) {
        size_t n = 0;
        int letter = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || *p >= 0xC0;
        if (!letter) { p++; continue; }
        while (*p) {
            int l = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || *p >= 0xC0;
            if (!l && !(*p == '\'' && ((p[1] >= 'A' && p[1] <= 'Z') || (p[1] >= 'a' && p[1] <= 'z')))) break;
            if (n + 1 < sizeof w) w[n++] = (char)ev_lower(*p);
            p++;
        }
        w[n] = 0;
        if (n > 1 && n + 1 < sizeof w) ev_word_candidates(w, fn, user);
    }
}

/* Every word of `text` exactly as written (letters only, no stems): for the main file's
   capitalisation fallback. */
static void ev_each_word_as_written(const char *text, int (*fn)(const char *word, void *user), void *user)
{
    const unsigned char *p = (const unsigned char *)text;
    char w[128];
    while (*p) {
        size_t n = 0;
        int letter = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || *p >= 0xC0;
        if (!letter) { p++; continue; }
        while (*p && ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || *p >= 0xC0)) {
            if (n + 1 < sizeof w) w[n++] = (char)*p;
            p++;
        }
        w[n] = 0;
        if (n > 1 && n + 1 < sizeof w) fn(w, user);
    }
}

/* Eloquence takes BYTES, not UTF-8 (docs/quirks.md "Text is bytes, not UTF-8"). First pass: fold
   the Latin-1 range to single bytes, the usual typographic characters to ASCII, everything else
   to a space. Invisible FORMAT characters are dropped outright, not turned into a space: WhatsApp's
   rows in VoiceOver glue a U+200E LEFT-TO-RIGHT MARK to the front of names ("\u200eMaybe Zoe"),
   and a zero-width space, joiner or soft hyphen INSIDE a word would otherwise split it in two
   ("hel\u00adlo" is "hel lo" to the engine, and to Apple's 6.1 too - measured 2026-09-24). The
   engine never sees these: none of them has a Windows-1252 byte but the soft hyphen, 0xAD.
   ⚠️ A proper sanitizer (ClassicVoices' cv_sanitize is the model) is still to come. */
static int ev_is_format_char(uint32_t cp)
{
    return cp == 0x00AD                      /* soft hyphen */
        || cp == 0x034F                      /* combining grapheme joiner */
        || cp == 0x061C                      /* arabic letter mark */
        || cp == 0x180E                      /* mongolian vowel separator */
        || (cp >= 0x200B && cp <= 0x200F)    /* zero-width space, non-joiner, joiner, LRM, RLM */
        || (cp >= 0x202A && cp <= 0x202E)    /* bidi embeddings and overrides */
        || (cp >= 0x2060 && cp <= 0x2064)    /* word joiner, invisible operators */
        || (cp >= 0x2066 && cp <= 0x206F)    /* bidi isolates, deprecated format controls */
        || cp == 0xFEFF;                     /* zero-width no-break space / byte order mark */
}

/* Windows-1252's own characters in 0x80-0x9F (the bytes the engine reads as the euro sign, a bullet,
   the French oe ligature ... - measured on the Mac against Apple 6.1: "5 \x80" is "five euros" in
   both). The quotes and dashes are left to their ASCII forms above, which English's punctuation rules
   read best, and the bullet (0x95) stays a space as it always was: the engine would say "bullet" for
   every list item VoiceOver reads. */
static int ev_cp1252_high(uint32_t cp)
{
    static const struct { uint16_t cp; unsigned char b; } t[] = {
        { 0x20AC, 0x80 }, { 0x201A, 0x82 }, { 0x0192, 0x83 }, { 0x201E, 0x84 }, { 0x2020, 0x86 },
        { 0x2021, 0x87 }, { 0x02C6, 0x88 }, { 0x2030, 0x89 }, { 0x0160, 0x8A }, { 0x2039, 0x8B },
        { 0x0152, 0x8C }, { 0x017D, 0x8E }, { 0x02DC, 0x98 }, { 0x2122, 0x99 },
        { 0x0161, 0x9A }, { 0x203A, 0x9B }, { 0x0153, 0x9C }, { 0x017E, 0x9E }, { 0x0178, 0x9F },
    };
    size_t i;
    for (i = 0; i < sizeof t / sizeof t[0]; i++) if (t[i].cp == cp) return t[i].b;
    return -1;
}

/* One UTF-8 character at s[i] (n bytes in all): its code point and length; a malformed byte is ' ', 1. */
static uint32_t ev_utf8_at(const char *s, size_t n, size_t i, int *len)
{
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { *len = 1; return c; }
    if ((c & 0xE0) == 0xC0 && i + 1 < n) { *len = 2; return ((c & 0x1F) << 6) | (s[i + 1] & 0x3F); }
    if ((c & 0xF0) == 0xE0 && i + 2 < n) { *len = 3; return ((c & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F); }
    if ((c & 0xF8) == 0xF0 && i + 3 < n) { *len = 4; return ((c & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12) | ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F); }
    *len = 1;
    return ' ';
}

/* The Western European languages: UTF-8 folded to Windows-1252 bytes. */
static char *ev_text_to_bytes(const char *utf8)
{
    size_t n = strlen(utf8);
    char *out = (char *)malloc(n + 1);
    size_t i = 0, o = 0;
    if (!out) return NULL;
    while (i < n) {
        int len, hb;
        uint32_t cp = ev_utf8_at(utf8, n, i, &len);
        i += (size_t)len;
        if (ev_is_format_char(cp)) continue;
        if (cp < 0x80) out[o++] = (char)cp;
        else if (cp >= 0xA0 && cp <= 0xFF) out[o++] = (char)cp;          /* Latin-1 */
        else if (cp == 0x2018 || cp == 0x2019) out[o++] = '\'';
        else if (cp == 0x201C || cp == 0x201D) out[o++] = '"';
        else if (cp == 0x2013 || cp == 0x2014) out[o++] = '-';
        else if (cp == 0x2026) { out[o++] = '.'; out[o++] = '.'; out[o++] = '.'; }
        else if ((hb = ev_cp1252_high(cp)) >= 0) out[o++] = (char)hb;
        else out[o++] = ' ';
    }
    out[o] = 0;
    return out;
}

/* Text the engine takes as UTF-8 (ev_lang_takes_utf8): only the invisible format characters come out. */
static char *ev_text_utf8_clean(const char *utf8)
{
    size_t n = strlen(utf8);
    char *out = (char *)malloc(n + 1);
    size_t i = 0, o = 0;
    if (!out) return NULL;
    while (i < n) {
        int len;
        uint32_t cp = ev_utf8_at(utf8, n, i, &len);
        if (!ev_is_format_char(cp)) { memcpy(out + o, utf8 + i, (size_t)len); o += (size_t)len; }
        i += (size_t)len;
    }
    out[o] = 0;
    return out;
}

/* The pre-pass can be turned off for comparisons on the Mac: never by the app. */
static int ev_prepass_off = 0;
void ev_set_text_prepass(int on) { ev_prepass_off = on ? 0 : 1; }

/* "Enable backquote voice tags" (NVDA's IBMTTS driver's option, same default: OFF). Process-wide; the
   app's switch reaches it through configureEngine() before every request. */
static volatile int ev_voice_tags_on = 0;

void ev_set_voice_tags(int on) { ev_voice_tags_on = on ? 1 : 0; }
int ev_voice_tags(void) { return ev_voice_tags_on; }

/* The text as the engine gets it: folded to bytes, and - unless voice tags are on - every backtick made
   a space, exactly as NVDA's driver does it (`text.replace(b'`', b' ')` after encoding, so a character
   that folded to a backtick is caught too). With tags off a stray backtick can neither start an
   annotation nor be read out as "backquote". */
/* Whether the engine is handed this language's text as UTF-8 (ev_bridge.h "LANGUAGES"). */
static int ev_lang_takes_utf8(int32_t lang)
{
#if defined(EV_RELOQ_LATIN_UTF8) && EV_RELOQ_LATIN_UTF8
    /* Mac comparison builds only: every language as UTF-8, the way ReLoq's NVDA and Android hosts send it. */
    (void)lang;
    return 1;
#else
    /* ReLoq C: the scripts Windows-1252 cannot hold go in as UTF-8 (eciAddTextUtf8); the Latin-script
       ones stay Windows-1252 bytes through eciAddText, so the dictionaries (cp1252 files, matched on
       these bytes) work exactly as with IBM's engine. */
    return lang == EV_LANG_ZHCN || lang == EV_LANG_JAJP || lang == EV_LANG_KOKR || lang == EV_LANG_ELGR
        || lang == EV_LANG_PLPL;
#endif
}

/* openevv's US English text pre-pass, for ReLoq C (openevv does it inside the engine). ev_marks.inc says what
   and why. The stub runs it too, so `make test` sees what ReLoq is handed. */
#include "ev_marks.inc"

static char *ev_prepare_text(const char *utf8, int32_t lang)
{
    char *b = ev_lang_takes_utf8(lang) ? ev_text_utf8_clean(utf8) : ev_text_to_bytes(utf8), *p;
    if (b && !ev_voice_tags_on)
        for (p = b; *p; p++) if (*p == '`') *p = ' ';
    /* US English only, as openevv: the mode is 0 (default reading) unless the text itself sets one with `ts,
       which mk_rewrite follows token by token */
    if (b && lang == EV_LANG_ENUS && !ev_prepass_off) {
        char *r = mk_prepass(b, 0);
        if (r) { free(b); b = r; }
    }
    return b;
}

/* "Phrase prediction" (ev_bridge.h): process-wide, default ON; the app's switch reaches it through
   configureEngine() before every request. */
static volatile int ev_phrase_prediction_on = 1;

void ev_set_phrase_prediction(int on) { ev_phrase_prediction_on = on ? 1 : 0; }
int ev_phrase_prediction(void) { return ev_phrase_prediction_on; }

/* The tone controls (ev_bridge.h), packed into ONE word so a request on another thread never reads half of a
   change: bits 0-4 bass + 12, 5-9 midrange + 12, 10-14 treble + 12, bit 15 Mellow. 12|12<<5|12<<10 = all flat. */
#define EV_TONE_FLAT (12 | 12 << 5 | 12 << 10)
static volatile int ev_tone_word = EV_TONE_FLAT;
static int ev_tone_clamp(int db) { return db < -12 ? -12 : db > 12 ? 12 : db; }
void ev_set_tone(int bass_db, int mid_db, int treble_db, int mellow)
{
    ev_tone_word = (ev_tone_clamp(bass_db) + 12) | (ev_tone_clamp(mid_db) + 12) << 5
                 | (ev_tone_clamp(treble_db) + 12) << 10 | (mellow ? 1 : 0) << 15;
}
void ev_tone(int *bass_db, int *mid_db, int *treble_db, int *mellow)
{
    int w = ev_tone_word;
    if (bass_db) *bass_db = (w & 31) - 12;
    if (mid_db) *mid_db = (w >> 5 & 31) - 12;
    if (treble_db) *treble_db = (w >> 10 & 31) - 12;
    if (mellow) *mellow = w >> 15 & 1;
}

/* "Shorten pauses" (ev_bridge.h): RELOQ_ECI_PAUSE_MODE, 0 (ReLoq's default) ... 2. One int, so a request on
   another thread reads either the old value or the new one. */
static volatile int ev_pause_mode_on = 0;
void ev_set_pause_mode(int mode) { ev_pause_mode_on = mode < 0 ? 0 : mode > 2 ? 2 : mode; }
int ev_pause_mode(void) { return ev_pause_mode_on; }

int ev_text_fold(const char *utf8, char *out, int room) { return ev_text_fold_lang(utf8, EV_LANG_ENUS, out, room); }

int ev_text_fold_lang(const char *utf8, int32_t lang, char *out, int room)
{
    char *b;
    if (!out || room <= 0) return -1;
    out[0] = 0;
    if (!utf8) return 0;
    b = ev_prepare_text(utf8, lang);
    if (!b) return -1;
    strncpy(out, b, (size_t)room - 1);
    out[room - 1] = 0;
    free(b);
    return (int)strlen(out);
}

#if ELOQUENCE_ENGINE

/* ======================================================================
 * THE ENGINE SEAM - the real engine through include/eci.h
 * ======================================================================
 *
 * What this expects (Engine/README.md; `make engine` puts them there):
 *   - Engine/reloq-include/eci.h, reloq_eci.h, reloq_build.h   ReLoq C's published headers and
 *                                     the build line;
 *   - Engine/reloq.xcframework        ReLoq C as one static archive per slice (iPhone, iPhone
 *                                     simulator, Mac), linked into EloquenceEngine.framework;
 *   - ECI_STATIC defined for this file too, so eci.h declares plain functions.
 *
 * How the engine is driven (docs/using.md "Route one", docs/quirks.md):
 *   eciNewEx -> eciRegisterCallback -> eciSetOutputBuffer (FIRST, or eciAddText refuses: the
 *   engine has no audio device here) -> per utterance: eciSetParam(eciSampleRate) when the rate
 *   changed, eciCopyVoice(preset -> 0), eciSetVoiceParam x 8 on voice 0, eciAddText,
 *   eciSynthesize, then poll eciSpeaking (that pumps the message queue) and eciSynchronize.
 *   The callback runs on the engine's own thread; it copies samples out and returns
 *   eciDataProcessed, or eciDataAbort to stop (the engine then finishes the message it is on and
 *   goes quiet - nothing can abandon an utterance). It must never call back into the instance.
 *
 * The sample rate is a runtime setting of an instance: ReLoq C takes the seven ECI rate codes and
 * synthesises at each (ev_bridge.h, ev_sample_rate_supported).
 */

#ifndef ECI_STATIC
#define ECI_STATIC 1
#endif
/* Which engine source the archive was built from, written when the xcframework is copied in
   (Engine/README.md), so the extension's status line says which engine is really loaded:
   Engine/reloq-include/reloq_build.h. */
#if defined(__has_include)
#if EV_RELOQ && __has_include("reloq_build.h")
#include "reloq_build.h"
#endif
#endif
#ifndef EV_ENGINE_BUILD
#define EV_ENGINE_BUILD "unknown"
#endif
#include "eci.h"
#include <time.h>
#ifndef ECI_VERSION_LENGTH
#define ECI_VERSION_LENGTH 20        /* ReLoq's eci.h has no name for it; the ECI convention is 20 */
#endif

#define EV_FRAME 2048

struct ev_voice {
    ECIHand   h;
    int       preset;
    short     frame[EV_FRAME];
    ev_pcm_fn cb;
    void     *user;
    int       stopped;
    int32_t   rate_hz;      /* what the instance is set to; 0 = not yet set by us */
    ECIDictHand dict;       /* the community dictionary set in force, or NULL */
    int       dict_gen;     /* the ev_dict_gen it was built for */
    int       main_rc, abbr_rc, root_added;
    int       user_added;   /* the user's own main + abbreviation entries the engine took */
    int       input_type;   /* eciInputType as last set: 0 plain text (the engine's default), 1 annotations */
    int32_t   lang;         /* the engine's language/dialect number (EV_LANG_*) */
    int       phrase_pred;  /* the phrase prediction (env 11) the instance has */
    int       tone;         /* ReLoq: the tone word (ev_tone_word) the instance has; EV_TONE_FLAT = ReLoq's defaults */
    int       pause_mode;   /* ReLoq: RELOQ_ECI_PAUSE_MODE as the instance has it; 0 = ReLoq's default */
    int       engine_error; /* ReLoq: RELOQ_ECI_LAST_ERROR after a failed eciSynthesize (0 = none) */
    int       engine_stage; /* ReLoq: RELOQ_ECI_FAILURE_STAGE with it */
};

/* Environment parameter 11, phrase prediction. eci.h gives it no name (IBM's did not publish one). */
#define EV_ECI_PHRASE_PREDICTION 11

static int ECICALL ev_on_message(ECIHand h, ECIMessage msg, int param, void *data);

/* A new engine instance for `v`, made with phrase prediction `pp`, its callback and output buffer in
   place. Returns 0 ok, -1 failed (v->h is then NULL_ECI_HAND). */
static int ev_voice_new_instance(ev_voice *v, int pp)
{
    /* ReLoq C: phrase prediction is the instance's own parameter (and eciSetDefaultParam(11) is refused). */
    v->h = eciNewEx((int)v->lang);
    if (v->h == NULL_ECI_HAND && v->lang == EV_LANG_ENUS) v->h = eciNew();
    if (v->h == NULL_ECI_HAND) return -1;
    if (eciSetParam(v->h, EV_ECI_PHRASE_PREDICTION, pp) < 0) pp = eciGetParam(v->h, EV_ECI_PHRASE_PREDICTION);
    v->phrase_pred = pp;
    v->tone = EV_TONE_FLAT;   /* a new instance has ReLoq's defaults: flat, Mellow off */
    v->pause_mode = 0;        /* and its original pauses */
    v->rate_hz = 0;
    v->input_type = 0;
    eciRegisterCallback(v->h, ev_on_message, v);
    if (!eciSetOutputBuffer(v->h, EV_FRAME, v->frame)) {
        eciDelete(v->h);
        v->h = NULL_ECI_HAND;
        return -1;
    }
    return 0;
}

static int ECICALL ev_on_message(ECIHand h, ECIMessage msg, int param, void *data)
{
    ev_voice *v = (ev_voice *)data;
    (void)h;
    if (msg == eciWaveformBuffer) {
        if (v->stopped) return eciDataAbort;
        /* `param` is a count of SAMPLES; the buffer is reused for every message, so the consumer
           must have copied it before this returns (PCMStream.append does). */
        if (v->cb && v->cb(v->frame, param, v->user) != 0) {
            v->stopped = 1;
            return eciDataAbort;
        }
    }
    return eciDataProcessed;
}

int ev_engine_present(void) { return 1; }

const char *ev_engine_name(void) { return "reloq"; }
#ifndef EV_RELOQ_VERSION
#define EV_RELOQ_VERSION "?"
#endif

const char *ev_engine_description(void)
{
    static char desc[ECI_VERSION_LENGTH + 128];
    if (!desc[0]) {
        char ver[ECI_VERSION_LENGTH + 1];
        memset(ver, 0, sizeof ver);
        eciVersion(ver);
        /* ReLoq's eciVersion answers its ECI interface level ("1.2.2"), not the release: the release comes
           from the build header (the version its tree says it is). */
        snprintf(desc, sizeof desc, "ReLoq C %s ECI %s build %s", EV_RELOQ_VERSION, ver[0] ? ver : "?", EV_ENGINE_BUILD);
    }
    return desc;
}

void ev_voice_engine_error(ev_voice *v, int *code, int *stage)
{
    if (code) *code = v ? v->engine_error : 0;
    if (stage) *stage = v ? v->engine_stage : 0;
}

static int ECICALL ev_discard(ECIHand h, ECIMessage msg, int param, void *data)
{
    (void)h; (void)msg; (void)param; (void)data;
    return eciDataProcessed;
}

void ev_voice_prime(ev_voice *v)
{
    /* one letter, completed, into nothing: ReLoq then prepares the instance for the next request (ev_bridge.h) */
    if (!v || v->h == NULL_ECI_HAND) return;
    eciRegisterCallback(v->h, ev_discard, NULL);
    eciClearInput(v->h);
    if (eciAddText(v->h, "a")) eciSynthesize(v->h);
    eciSynchronize(v->h);
    eciClearInput(v->h);
    eciRegisterCallback(v->h, ev_on_message, v);
}

ev_voice *ev_voice_open(int preset) { return ev_voice_open_lang(preset, EV_LANG_ENUS); }

ev_voice *ev_voice_open_lang(int preset, int32_t lang)
{
    ev_voice *v;
    if (preset < 1 || preset > EV_PRESETS || ev_lang_index(lang) < 0) return NULL;
    v = (ev_voice *)calloc(1, sizeof *v);
    if (!v) return NULL;
    v->preset = preset;
    v->lang = lang;
    v->main_rc = v->abbr_rc = -1;
    if (ev_voice_new_instance(v, ev_phrase_prediction_on) != 0) { free(v); return NULL; }
    return v;
}

void ev_voice_close(ev_voice *v)
{
    if (!v) return;
    if (v->h != NULL_ECI_HAND) eciDelete(v->h);
    free(v);
}

/* ---- the community dictionary on one handle ---- */

static void ev_voice_drop_dict(ev_voice *v)
{
    if (v->dict) {
        eciSetDict(v->h, NULL_DICT_HAND);
        eciDeleteDict(v->h, v->dict);
        v->dict = NULL;
    }
    v->main_rc = v->abbr_rc = -1;
    v->root_added = 0;
    v->user_added = 0;
}

typedef struct { ev_voice *v; } ev_root_ctx;

static int ev_root_add(const char *key, void *user)
{
    ev_voice *v = ((ev_root_ctx *)user)->v;
    const char *val = ev_root_value(key);
    const char *have;
    if (!val) return 0;
    have = eciDictLookup(v->h, v->dict, eciRootDict, key);
    if (have && *have) return 1;
    if (eciUpdateDict(v->h, v->dict, eciRootDict, key, val) == eciDictNoError) v->root_added++;
    return 1;
}

/* The engine matches main-file keys exactly, so "iOS" misses the file's "ios"/"IOS"/"Ios". For a word
   the file lists in several capitalisations, add the spelling actually written, with the same reading. */
static int ev_main_ci_add(const char *word, void *user)
{
    ev_voice *v = ((ev_root_ctx *)user)->v;
    char low[128];
    const char *val, *have;
    size_t i, n = strlen(word);
    if (n >= sizeof low) return 0;
    for (i = 0; i <= n; i++) low[i] = (char)ev_lower((unsigned char)word[i]);
    /* the user's own entry in any capitalisation first ("hello" also covers "Hello" at the start of a
       sentence), then the community file's words listed in several capitalisations */
    if (ev_skipped(low)) return 0;
    val = ev_dict_table_find(ev_user_main_ci, low);
    if (!val && v->main_rc == 0 && !ev_cur->community_off) val = ev_dict_table_find(ev_main_ci_table, low);
    if (!val) return 0;
    have = eciDictLookup(v->h, v->dict, eciMainDict, word);
    if (have && *have) return 0;
    if (eciUpdateDict(v->h, v->dict, eciMainDict, word, val) == eciDictNoError) v->root_added++;
    return 0;
}

/* Whether any dictionary at all is configured: the community files or the user's own. Lock held. */
static int ev_dict_any(void)
{
    return ev_dict_path[0][0] || ev_dict_path[1][0] || ev_dict_path[2][0]
        || ev_user_main || ev_user_root || ev_user_abbr;
}

/* Brings this handle's dictionary up to the process-wide configuration, then hands the engine the
   root entries for the words about to be spoken (ev_bridge.h says why not the whole file). */
/* ev_skipped for a key as written (the user's exact-case tables). Lock held. */
static int ev_skipped_exact(const char *key)
{
    char low[128];
    size_t i, n = strlen(key);
    if (n >= sizeof low) return 0;
    for (i = 0; i <= n; i++) low[i] = (char)ev_lower((unsigned char)key[i]);
    return ev_skipped(low);
}

static void ev_voice_prepare_dict(ev_voice *v, const char *bytes)
{
    ev_dict_slot *slot = ev_slot(v->lang);
    if (!slot) return;
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = slot;
    if (v->dict_gen != ev_dict_gen || v->root_added >= EV_DICT_ROOT_RESET) {
        ev_voice_drop_dict(v);
        if (ev_dict_any()) {
            v->dict = eciNewDict(v->h);
            if (v->dict) {
                int i;
                if (ev_dict_path[0][0] && !ev_cur->community_off)
                    v->main_rc = eciLoadDict(v->h, v->dict, eciMainDict, ev_dict_path[0]);
                if (ev_dict_path[2][0] && !ev_cur->community_off)
                    v->abbr_rc = eciLoadDict(v->h, v->dict, eciAbbvDict, ev_dict_path[2]);
                /* the user's own whole words and abbreviations on top: an entry with a community
                   entry's key replaces it (eciUpdateDict over a loaded key, measured 2026-09-24) */
                v->user_added = 0;
                for (i = 0; ev_user_main && i < ev_user_main->n; i++)
                    if (!ev_skipped_exact(ev_user_main->pairs[i].key)
                        && eciUpdateDict(v->h, v->dict, eciMainDict, ev_user_main->pairs[i].key,
                                         ev_user_main->pairs[i].val) == eciDictNoError) v->user_added++;
                for (i = 0; ev_user_abbr && i < ev_user_abbr->n; i++)
                    if (!ev_skipped_exact(ev_user_abbr->pairs[i].key)
                        && eciUpdateDict(v->h, v->dict, eciAbbvDict, ev_user_abbr->pairs[i].key,
                                         ev_user_abbr->pairs[i].val) == eciDictNoError) v->user_added++;
                if (eciSetDict(v->h, v->dict) != 0) ev_voice_drop_dict(v);
            }
        }
        v->dict_gen = ev_dict_gen;
    }
    if (v->dict && (ev_root_table || ev_user_root)) {
        ev_root_ctx ctx;
        ctx.v = v;
        ev_each_word(bytes, ev_root_add, &ctx);
    }
    if (v->dict && ((ev_main_ci_table && v->main_rc == 0) || ev_user_main_ci)) {
        ev_root_ctx ctx;
        ctx.v = v;
        ev_each_word_as_written(bytes, ev_main_ci_add, &ctx);
    }
    pthread_mutex_unlock(&ev_dict_lock);
}

void ev_voice_dict_report(ev_voice *v, ev_dict_report *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    out->main_rc = out->abbr_rc = -1;
    if (!v) return;
    out->in_force = v->dict != NULL;
    out->main_rc = v->main_rc;
    out->abbr_rc = v->abbr_rc;
    out->root_added = v->root_added;
    out->user_added = v->user_added;
}

int ev_voice_preset_params(ev_voice *v, ev_voice_params *out)
{
    if (!v || !out) return -1;
    out->gender            = eciGetVoiceParam(v->h, v->preset, eciGender);
    out->head_size         = eciGetVoiceParam(v->h, v->preset, eciHeadSize);
    out->pitch_baseline    = eciGetVoiceParam(v->h, v->preset, eciPitchBaseline);
    out->pitch_fluctuation = eciGetVoiceParam(v->h, v->preset, eciPitchFluctuation);
    out->roughness         = eciGetVoiceParam(v->h, v->preset, eciRoughness);
    out->breathiness       = eciGetVoiceParam(v->h, v->preset, eciBreathiness);
    out->speed             = eciGetVoiceParam(v->h, v->preset, eciSpeed);
    out->volume            = eciGetVoiceParam(v->h, v->preset, eciVolume);
    return 0;
}

void ev_voice_engine_name(ev_voice *v, char *out, int room)
{
    char name[ECI_VOICE_NAME_LENGTH + 1];
    if (!out || room <= 0) return;
    out[0] = 0;
    if (!v) return;
    memset(name, 0, sizeof name);
    if (eciGetVoiceName(v->h, v->preset, name)) {
        strncpy(out, name, (size_t)room - 1);
        out[room - 1] = 0;
    }
}

int ev_voice_speak(ev_voice *v, const char *text, const ev_request *req, ev_pcm_fn cb, void *user)
{
    ev_voice_params eff;
    char *bytes;
    struct timespec nap = { 0, 2 * 1000 * 1000 };
    int i;

    if (!v || !req || !cb) return -1;
    if (ev_speakable_chars(text) == 0) return 0;
    if (!ev_sample_rate_supported(req->sample_rate)) return -1;

    /* ReLoq C: phrase prediction is the instance's own parameter; set it when it changed. */
    if (v->phrase_pred != ev_phrase_prediction_on) {
        if (eciSetParam(v->h, EV_ECI_PHRASE_PREDICTION, ev_phrase_prediction_on) < 0) return -1;
        v->phrase_pred = ev_phrase_prediction_on;
    }
    /* The tone controls: each told to the instance only when it differs from what the instance has, so at the
       defaults (EV_TONE_FLAT, ReLoq's own) nothing is ever set. ReLoq builds the equaliser afresh for every
       synthesis from these, and Mellow is read at every eciSynthesize: the next utterance hears a change. */
    {
        int want = ev_tone_word;
        if (want != v->tone) {
            if ((want & 31) != (v->tone & 31) && eciSetParam(v->h, RELOQ_ECI_EQ_LOW, want & 31) < 0) return -1;
            if ((want >> 5 & 31) != (v->tone >> 5 & 31) && eciSetParam(v->h, RELOQ_ECI_EQ_MID, want >> 5 & 31) < 0) return -1;
            if ((want >> 10 & 31) != (v->tone >> 10 & 31) && eciSetParam(v->h, RELOQ_ECI_EQ_HIGH, want >> 10 & 31) < 0) return -1;
            if ((want >> 15 & 1) != (v->tone >> 15 & 1) && eciSetParam(v->h, RELOQ_ECI_MELLOW_MODE, want >> 15 & 1) < 0) return -1;
            v->tone = want;
        }
    }
    /* "Shorten pauses", the same way: told to the instance only when it differs, so at the default (0, the
       original pauses) nothing is set. The engine reads it at every synthesis: the next utterance hears it. */
    {
        int want = ev_pause_mode_on;
        if (want != v->pause_mode) {
            if (eciSetParam(v->h, RELOQ_ECI_PAUSE_MODE, want) < 0) return -1;
            v->pause_mode = want;
        }
    }

    ev_apply_prosody(&req->voice, &req->prosody, &eff);

    /* The rate. Set only when it changes: setting it rebuilds the output path (ReLoq: both its
       sessions). eciSetParam answers -1 when it refused.
       ReLoq C takes the ECI rate CODE (0-6), and synthesises at that rate.
       openevv takes hertz (eci.h: "any number of 8,000 or more as a rate in hertz"). */
    if (v->rate_hz != req->sample_rate) {
        if (eciSetParam(v->h, eciSampleRate, ev_rate_code(req->sample_rate)) < 0) return -1;
        v->rate_hz = req->sample_rate;
    }

    /* Voice 0 is the one spoken in; start from the preset, then the eight. */
    if (!eciCopyVoice(v->h, v->preset, 0)) return -1;
    {
        const int32_t vals[8] = { eff.gender, eff.head_size, eff.pitch_baseline, eff.pitch_fluctuation,
                                  eff.roughness, eff.breathiness, eff.speed, eff.volume };
        for (i = 0; i < 8; i++) {
            if (eciSetVoiceParam(v->h, 0, i, vals[i]) < 0) return -1;
        }
    }

    bytes = ev_prepare_text(text, v->lang);
    if (!bytes) return -1;

    /* Annotations: eciInputType 1 only while voice tags are on (NVDA sets 1 and strips the backticks
       instead; with every backtick already gone the two read the same, and 0 keeps the engine's input
       exactly what it was before the option existed). While tags are on, a `ts left in force by an
       earlier utterance on this pooled handle is put back to ordinary reading first. */
    {
        int want = ev_voice_tags_on ? 1 : 0;
        if (v->input_type != want) {
            if (eciSetParam(v->h, eciInputType, want) < 0) { free(bytes); return -1; }
            v->input_type = want;
        }
        if (want && eciGetParam(v->h, eciTextMode) != 0) eciSetParam(v->h, eciTextMode, 0);
    }

    ev_voice_prepare_dict(v, bytes);

    v->cb = cb;
    v->user = user;
    v->stopped = 0;
    v->engine_error = 0;
    v->engine_stage = 0;

    /* ReLoq C runs the whole utterance INSIDE eciSynthesize, on this thread, and reports a callback's
       eciDataAbort as a failure (RELOQ_ECI_CALLBACK; a concurrent stop as RELOQ_ECI_CANCELLED), where
       openevv answers success and the bridge reads v->stopped - so a stop we asked for is a stop, not an
       error. Its own hosts clear the input queue around every job (android/native/reloq_jni.c): a
       refused job leaves its text queued otherwise. */
    (void)nap;
    eciClearInput(v->h);
    {
        int added = ev_lang_takes_utf8(v->lang) ? eciAddTextUtf8(v->h, bytes, strlen(bytes), 0)
                                                : eciAddText(v->h, bytes);
        int ok = added && eciSynthesize(v->h);
        if (!ok) {
            int err = eciGetParam(v->h, RELOQ_ECI_LAST_ERROR);
            int stopped_by_us = v->stopped && (err == RELOQ_ECI_CALLBACK || err == RELOQ_ECI_CANCELLED);
            if (!stopped_by_us) {
                v->engine_error = err ? err : -1;
                v->engine_stage = eciGetParam(v->h, RELOQ_ECI_FAILURE_STAGE);
            }
        }
        eciSynchronize(v->h);
        eciClearInput(v->h);
        free(bytes);
        v->cb = NULL;
        if (v->stopped) return 1;
        return ok ? 0 : -1;
    }
}

#else /* !ELOQUENCE_ENGINE */

/* ======================================================================
 * THE STUB - a tone shaped by the eight parameters, the prosody and the rate
 * ======================================================================
 *
 * What each dial does to the tone, so every one of them is audible and measurable:
 *   pitch baseline     the tone's frequency: 80 Hz x 2^(pitch / 40)  (65 -> 247 Hz, 100 -> 452 Hz)
 *   gender             1 (female) raises it three semitones on top of that
 *   pitch fluctuation  a 5 Hz vibrato, depth 6 % x (fluctuation / 100)
 *   head size          the second harmonic's level: (1 - head / 100) x 0.5 (a big head = darker)
 *   roughness          amplitude jitter, (roughness / 100) x 30 %
 *   breathiness        added white noise, (breathiness / 100) x 15 % of full scale
 *   speed              the tone's length: 55 ms per letter or digit at speed 50, following the engine's
 *                      MEASURED curve (exponential, 49.6 units per e-fold - see ev_speed_units), so
 *                      units 100 is 2.7x shorter and 70 is 1.5x, exactly as the real engine does it
 *   volume             the level: 0.3 x (volume / 100) of full scale
 *   sample rate        the tone is generated at that rate (so 22050 gives twice the samples)
 * Prosody lands through ev_apply_prosody exactly as it will on the engine. The noise is a fixed-seed
 * generator, so the same request gives the same samples every time.
 */

static const ev_voice_params ev_stub_presets[EV_PRESETS] = {
    /* the eight presets as the openevv engine listed them (`evv -l`, 2026-09-22), "in the engine's own units":
       gender, head size, pitch, fluctuation, roughness, breathiness, speed, volume */
    { 0, 50, 65, 30,  0,  0, 50,  92 },  /* voice 1  Adult Male 1     Reed    */
    { 1, 50, 81, 30,  0, 50, 50, 100 },  /* voice 2  Adult Female 1   Shelley */
    { 1, 22, 93, 35,  0,  0, 50,  90 },  /* voice 3  Child 1          Bobby   */
    { 0, 89, 52, 43,  0,  0, 50,  93 },  /* voice 4  Adult Male 2     Rocko   */
    { 0, 50, 69, 34,  0,  0, 70,  92 },  /* voice 5  Adult Male 3     Glen    */
    { 1, 56, 89, 35,  0, 40, 70,  95 },  /* voice 6  Adult Female 2   Sandy   */
    { 1, 45, 68, 30,  3, 40, 50,  90 },  /* voice 7  Elderly Female 1 Grandma */
    { 0, 30, 61, 44, 18, 20, 50,  90 },  /* voice 8  Elderly Male 1   Grandpa */
};

struct ev_voice {
    int preset;
    int32_t lang;
};

int ev_engine_present(void) { return 0; }
const char *ev_engine_name(void) { return "stub"; }
const char *ev_engine_description(void) { return "stub tone generator (no speech engine linked)"; }
void ev_voice_engine_error(ev_voice *v, int *code, int *stage) { (void)v; if (code) *code = 0; if (stage) *stage = 0; }
void ev_voice_prime(ev_voice *v) { (void)v; }

ev_voice *ev_voice_open(int preset) { return ev_voice_open_lang(preset, EV_LANG_ENUS); }

ev_voice *ev_voice_open_lang(int preset, int32_t lang)
{
    ev_voice *v;
    if (preset < 1 || preset > EV_PRESETS || ev_lang_index(lang) < 0) return NULL;
    v = (ev_voice *)calloc(1, sizeof *v);
    if (!v) return NULL;
    v->preset = preset;
    v->lang = lang;
    return v;
}

void ev_voice_close(ev_voice *v) { free(v); }

/* The stub speaks no words, so it has no dictionary to put in force; the files are still parsed by
   ev_dict_configure (the root table) and ev_dict_count_entries, which is what `make test` checks. */
void ev_voice_dict_report(ev_voice *v, ev_dict_report *out)
{
    (void)v;
    if (!out) return;
    memset(out, 0, sizeof *out);
    out->main_rc = out->abbr_rc = -1;
}

/* For the Mac test: the root entries the engine half would hand over for `text`. */
typedef struct { char *out; size_t room; int n; } ev_stub_root_ctx;
static int ev_stub_root_collect(const char *key, void *user)
{
    ev_stub_root_ctx *c = (ev_stub_root_ctx *)user;
    const char *val = ev_root_value(key);
    if (!val) return 0;
    if (strlen(c->out) + strlen(key) + strlen(val) + 3 < c->room) {
        strcat(c->out, key); strcat(c->out, "="); strcat(c->out, val); strcat(c->out, ";");
    }
    c->n++;
    return 1;
}
int ev_stub_root_matches(const char *text, char *out, int room)
{
    ev_stub_root_ctx c;
    if (!out || room <= 0) return 0;
    out[0] = 0;
    c.out = out; c.room = (size_t)room; c.n = 0;
    pthread_mutex_lock(&ev_dict_lock);
    ev_cur = &ev_slots[0];
    ev_each_word(text, ev_stub_root_collect, &c);
    pthread_mutex_unlock(&ev_dict_lock);
    return c.n;
}

int ev_voice_preset_params(ev_voice *v, ev_voice_params *out)
{
    if (!v || !out) return -1;
    *out = ev_stub_presets[v->preset - 1];
    return 0;
}

void ev_voice_engine_name(ev_voice *v, char *out, int room)
{
    if (!out || room <= 0) return;
    snprintf(out, (size_t)room, "Stub voice %d", v ? v->preset : 0);
}

int ev_voice_speak(ev_voice *v, const char *text, const ev_request *req, ev_pcm_fn cb, void *user)
{
    ev_voice_params eff;
    int chars, rate, total, made = 0;
    double hz, dur, amp, vib, h2, rough, breath;
    uint32_t seed = 0x9E3779B9u;
    int16_t chunk[1024];

    if (!v || !req || !cb) return -1;
    chars = ev_speakable_chars(text);
    if (chars == 0) return 0;                       /* nothing to say: no audio at all */
    if (!ev_sample_rate_supported(req->sample_rate)) return -1;
    rate = req->sample_rate;

    ev_apply_prosody(&req->voice, &req->prosody, &eff);

    hz = 80.0 * pow(2.0, eff.pitch_baseline / 40.0);
    if (eff.gender) hz *= pow(2.0, 3.0 / 12.0);
    dur = 0.055 * chars * exp(-(eff.speed - EV_STANDARD_SPEED) / EV_SPEED_UNITS_PER_EFOLD);
    if (dur < 0.12) dur = 0.12;
    if (dur > 6.0) dur = 6.0;
    amp = 0.3 * eff.volume / 100.0;
    vib = 0.06 * eff.pitch_fluctuation / 100.0;
    h2 = 0.5 * (1.0 - eff.head_size / 100.0);
    rough = 0.3 * eff.roughness / 100.0;
    breath = 0.15 * eff.breathiness / 100.0;
    total = (int)(dur * rate);

    {
        double phase = 0.0, fade_n = 0.010 * rate;
        int i = 0;
        while (i < total) {
            int n = total - i < 1024 ? total - i : 1024, k;
            for (k = 0; k < n; k++, i++) {
                double t = (double)i / rate;
                double f = hz * (1.0 + vib * sin(2 * M_PI * 5.0 * t));
                double env = 1.0;
                double s, noise, jitter;
                seed = seed * 1664525u + 1013904223u;
                noise = ((seed >> 8) / 8388608.0) - 1.0;      /* -1 ... 1 */
                seed = seed * 1664525u + 1013904223u;
                jitter = 1.0 + rough * (((seed >> 8) / 8388608.0) - 1.0);
                phase += 2 * M_PI * f / rate;
                if (i < fade_n) env = i / fade_n;
                if (total - i < fade_n) env = (total - i) / fade_n;
                s = (sin(phase) + h2 * sin(2 * phase)) / (1.0 + h2) * jitter + breath * noise;
                s *= amp * env;
                if (s > 1.0) s = 1.0;
                if (s < -1.0) s = -1.0;
                chunk[k] = (int16_t)(s * 32767.0);
            }
            made += n;
            if (cb(chunk, n, user) != 0) return 1;
        }
    }
    (void)made;
    return 0;
}

#endif /* ELOQUENCE_ENGINE */
