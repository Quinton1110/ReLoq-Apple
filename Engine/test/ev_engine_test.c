/*
 * ev_engine_test.c - the ENGINE half of the bridge on the Mac, linked against ReLoq C's Mac slice
 * (Engine/reloq.xcframework/macos-arm64/libreloq.a, the same source as the phone's archive).
 * `make engine-test [DICT_DIR=dir-with-ENUmain.dic-ENURoot.dic-ENUabbr.dic]`.
 *
 * The bridge's source is included here (not linked) so the test can reach a handle's engine instance
 * and ask it for PHONEMES - the only direct proof that a dictionary entry took.
 *
 *   1. pitch: renders with VoiceOver-sized pitch shifts, measures the fundamental by autocorrelation
 *      and compares the shift in semitones with the one asked for;
 *   2. dictionary (DICT_DIR): words through ev_voice_speak with the dictionary configured, then their
 *      phonemes from the same instance, against a handle with none; timings of the loads.
 *   ... 6. phrase prediction on / off (sample counts, byte comparisons, a pooled handle switched);
 *   ... 10. "Shorten pauses" Never / Only at end of text / Always (sample counts, a handle in use switched).
 * Exit status non-zero on a failed check.
 */
#include "../../Shared/Bridge/ev_bridge.c"

#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

static int failures;
#define CHECK(cond, ...) do { if (cond) printf("ok   " __VA_ARGS__); else { printf("FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

typedef struct { int16_t *pcm; int n, cap; } buf_t;

static int collect(const int16_t *pcm, int n, void *user)
{
    buf_t *b = (buf_t *)user;
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 4096;
        b->pcm = (int16_t *)realloc(b->pcm, (size_t)b->cap * sizeof *b->pcm);
    }
    memcpy(b->pcm + b->n, pcm, (size_t)n * sizeof *pcm);
    b->n += n;
    return 0;
}

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/* Median fundamental over voiced 40 ms frames (normalised autocorrelation peak > 0.5, 50-600 Hz). */
static double median_f0(const buf_t *b, int rate)
{
    int fr = (int)(0.04 * rate), hop = (int)(0.01 * rate), lo = rate / 600, hi = rate / 50, i, n = 0;
    double *f = (double *)malloc(sizeof(double) * (size_t)(b->n / hop + 1)), med;
    for (i = 0; i + fr + hi < b->n; i += hop) {
        double e = 0, best = 0, mean = 0;
        int lag, bestlag = 0, k;
        for (k = 0; k < fr; k++) mean += b->pcm[i + k];
        mean /= fr;
        for (k = 0; k < fr; k++) e += (b->pcm[i + k] - mean) * (b->pcm[i + k] - mean);
        if (e < (double)fr * 300 * 300) continue;
        for (lag = lo; lag <= hi; lag++) {
            double c = 0, e2 = 0;
            for (k = 0; k < fr; k++) {
                double x = b->pcm[i + k] - mean, y = b->pcm[i + k + lag] - mean;
                c += x * y;
                e2 += y * y;
            }
            c /= sqrt(e * e2) + 1e-9;
            if (c > best) { best = c; bestlag = lag; }
        }
        if (best > 0.5 && bestlag > 0) f[n++] = (double)rate / bestlag;
    }
    if (n == 0) { free(f); return 0; }
    qsort(f, (size_t)n, sizeof(double), cmp_d);
    med = f[n / 2];
    free(f);
    return med;
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

/* ---- phonemes from a handle's own instance ---- */

static char phon_room[8192];
static char phon_said[32768];

static int ECICALL on_phonemes(ECIHand h, ECIMessage msg, int param, void *data)
{
    (void)h; (void)data;
    if (msg == eciPhonemeBuffer) strncat(phon_said, phon_room, (size_t)param);
    return eciDataProcessed;
}

static const char *phonemes(ev_voice *v, const char *word)
{
    phon_said[0] = 0;
    memset(phon_room, 0, sizeof phon_room);
    eciRegisterCallback(v->h, on_phonemes, NULL);
    eciSetParam(v->h, eciSynthMode, 1);
    eciAddText(v->h, word);
    eciGeneratePhonemes(v->h, sizeof phon_room, phon_room);
    eciClearInput(v->h);
    eciSetParam(v->h, eciSynthMode, 0);
    eciRegisterCallback(v->h, ev_on_message, v);
    return phon_said;
}

static buf_t say_at(ev_voice *v, const char *text, ev_voice_params vp, int hz, int *rc)
{
    ev_request r;
    buf_t b = { 0, 0, 0 };
    memset(&r, 0, sizeof r);
    r.voice = vp;
    r.prosody.speed = 1; r.prosody.range = 1; r.prosody.volume = 1;
    r.sample_rate = hz;
    *rc = ev_voice_speak(v, text, &r, collect, &b);
    return b;
}

static int same_pcm(buf_t a, buf_t b) { return a.n == b.n && a.n > 0 && memcmp(a.pcm, b.pcm, (size_t)a.n * 2) == 0; }

static buf_t say(ev_voice *v, const char *text, ev_voice_params vp, double st, int *rc)
{
    ev_request r;
    buf_t b = { 0, 0, 0 };
    memset(&r, 0, sizeof r);
    r.voice = vp;
    r.prosody.speed = 1; r.prosody.pitch_st = st; r.prosody.range = 1; r.prosody.volume = 1;
    r.sample_rate = EV_NATIVE_SAMPLE_RATE;
    *rc = ev_voice_speak(v, text, &r, collect, &b);
    return b;
}

int main(void)
{
    const char *sentence = "The quick brown fox jumps over the lazy dog, and then it runs away.";
    const char *dir = getenv("DICT_DIR");
    int preset, rc;
    printf("engine: %s\n", ev_engine_description());

    /* 1. pitch */
    for (preset = 1; preset <= 3; preset++) {
        static const double shifts[3] = { 0, 4.5, -2.8 };   /* +30 %, -15 %: VoiceOver's seen so far */
        ev_voice_params vp, told;
        double f0[3];
        int k;
        ev_voice *v = ev_voice_open(preset);
        ev_voice_preset_params(v, &vp);
        vp.speed = EV_STANDARD_SPEED;
        ev_voice_close(v);
        for (k = 0; k < 3; k++) {
            ev_prosody p = { 1, shifts[k], 1, 1 };
            buf_t b;
            v = ev_voice_open(preset);          /* fresh instance per render */
            b = say(v, sentence, vp, shifts[k], &rc);
            f0[k] = median_f0(&b, EV_NATIVE_SAMPLE_RATE);
            ev_apply_prosody(&vp, &p, &told);
            printf("     preset %d dial %d %+.1f st -> told %d (curve %.0f Hz): measured median F0 %.1f Hz\n",
                   preset, vp.pitch_baseline, shifts[k], told.pitch_baseline, ev_pitch_hz(told.pitch_baseline), f0[k]);
            free(b.pcm);
            ev_voice_close(v);
        }
        for (k = 1; k < 3; k++) {
            double got = 12 * log2(f0[k] / f0[0]);
            ev_prosody p = { 1, shifts[k], 1, 1 };
            ev_apply_prosody(&vp, &p, &told);
            if (told.pitch_baseline == EV_PITCH_CEILING && shifts[k] > 0) {
                /* a voice already near the top (Bobby, 93) is stopped at the ceiling on purpose */
                double room = 12 * log2(ev_pitch_hz(EV_PITCH_CEILING) / ev_pitch_hz(vp.pitch_baseline));
                CHECK(f0[0] > 0 && got > 0 && fabs(got - room) < 1.0,
                      "preset %d: asked %+.1f st, stopped at the ceiling (dial %d): %+.2f st of the %+.2f available (F0 %.1f -> %.1f Hz)",
                      preset, shifts[k], EV_PITCH_CEILING, got, room, f0[0], f0[k]);
            } else {
                CHECK(f0[0] > 0 && fabs(got - shifts[k]) < 1.0,
                      "preset %d: asked %+.1f st, measured %+.2f st (F0 %.1f -> %.1f Hz)", preset, shifts[k], got, f0[0], f0[k]);
            }
        }
    }

    /* 2. dictionary */
    if (!dir) {
        printf("(no DICT_DIR: dictionary checks skipped)\n");
    } else {
        static const char *words[] = { "iPhone", "iPhones", "iMessage", "iPad", "ios", "IOS", "iOS", "nvda", "WWII", "tabindex", "hello" };
        char mainp[1024], rootp[1024], abbrp[1024];
        ev_voice *plain, *withd;
        ev_voice_params vp;
        double t0;
        int i, changed = 0;
        buf_t b;
        snprintf(mainp, sizeof mainp, "%s/ENUmain.dic", dir);
        snprintf(rootp, sizeof rootp, "%s/ENURoot.dic", dir);
        snprintf(abbrp, sizeof abbrp, "%s/ENUabbr.dic", dir);
        plain = ev_voice_open(1);
        withd = ev_voice_open(1);
        ev_voice_preset_params(plain, &vp);

        /* before: no dictionary configured */
        b = say(plain, "warm up", vp, 0, &rc); free(b.pcm);

        t0 = now_ms();
        ev_dict_configure(mainp, rootp, abbrp);
        printf("     root table: %d entries, parsed and sorted in %.0f ms\n", ev_dict_root_entries(), now_ms() - t0);
        CHECK(ev_dict_root_entries() > 60000, "the root file parsed: %d entries", ev_dict_root_entries());

        t0 = now_ms();
        b = say(withd, "warm up", vp, 0, &rc); free(b.pcm);
        {
            ev_dict_report r;
            ev_voice_dict_report(withd, &r);
            printf("     first utterance with the dictionary (loads main + abbr): %.0f ms\n", now_ms() - t0);
            CHECK(r.in_force && r.main_rc == 0 && r.abbr_rc == 0, "set in force: main rc %d, abbr rc %d", r.main_rc, r.abbr_rc);
        }
        for (i = 0; i < (int)(sizeof words / sizeof words[0]); i++) {
            char before[512], after[512];
            b = say(withd, words[i], vp, 0, &rc); free(b.pcm);   /* hands the engine this word's root entries */
            strncpy(after, phonemes(withd, words[i]), sizeof after - 1); after[sizeof after - 1] = 0;
            strncpy(before, phonemes(plain, words[i]), sizeof before - 1); before[sizeof before - 1] = 0;
            if (strcmp(before, after)) changed++;
            printf("     %-10s without: %-32s with: %s%s\n", words[i], before, after, strcmp(before, after) ? "   CHANGED" : "");
        }
        CHECK(changed >= 7, "%d of %d words changed", changed, (int)(sizeof words / sizeof words[0]));
        {
            ev_dict_report r;
            ev_voice_dict_report(withd, &r);
            printf("     root entries handed to the engine so far: %d\n", r.root_added);
        }
        /* speed: the same sentence with and without the dictionary */
        {
            double tp = 0, td = 0;
            int k;
            for (k = 0; k < 3; k++) {
                t0 = now_ms(); b = say(plain, sentence, vp, 0, &rc); tp += now_ms() - t0; free(b.pcm);
                t0 = now_ms(); b = say(withd, sentence, vp, 0, &rc); td += now_ms() - t0; free(b.pcm);
            }
            printf("     render x3: without %.0f ms, with %.0f ms\n", tp / 3, td / 3);
            CHECK(td < tp * 1.3 + 20, "the dictionary does not slow speech: %.0f vs %.0f ms", td / 3, tp / 3);
        }
        /* off again: the next utterance drops the set */
        ev_dict_configure(NULL, NULL, NULL);
        b = say(withd, "iPhone", vp, 0, &rc); free(b.pcm);
        {
            ev_dict_report r;
            char a[512], c[512];
            ev_voice_dict_report(withd, &r);
            strncpy(a, phonemes(withd, "iPhone"), sizeof a - 1); a[sizeof a - 1] = 0;
            strncpy(c, phonemes(plain, "iPhone"), sizeof c - 1); c[sizeof c - 1] = 0;
            CHECK(!r.in_force && strcmp(a, c) == 0, "configured off: the set is dropped and iPhone is back to %s", a);
        }
        ev_voice_close(plain);
        ev_voice_close(withd);
    }
    /* 3. the user's own entries (always; with DICT_DIR also against the community files) - written to a
       temporary folder here, nothing persists. A ROOT entry's reading must be one word or a `[...]
       phoneme string: the engine ignores a root replacement with a space in it (measured 2026-09-24,
       "un red" as a root did nothing; as a whole word it works) - the editor enforces this. These run
       with backquote voice tags OFF (the default): the phoneme entries go through the dictionary API and
       work regardless. "unread" is a real case (2026-09-24: the engine
       says "unreed"); the test proves a user's own entry changes it, it does NOT ship one. */
    {
        char udir[512], umain[600], uroot[600], uabbr[600], cmain[1024], croot[1024], cabbr[1024];
        char before[512], after[512];
        const char *tmpdir = getenv("TMPDIR");
        ev_voice *plain, *withu;
        ev_voice_params vp;
        ev_dict_report r;
        FILE *f;
        buf_t b;
        snprintf(udir, sizeof udir, "%s/ev-user-dict-test-%d", tmpdir && *tmpdir ? tmpdir : "/tmp", (int)getpid());
        mkdir(udir, 0700);
        snprintf(umain, sizeof umain, "%s/user-main.dic", udir);
        snprintf(uroot, sizeof uroot, "%s/user-root.dic", udir);
        snprintf(uabbr, sizeof uabbr, "%s/user-abbr.dic", udir);
        f = fopen(uroot, "wb"); fputs("gloop\t`[.1wEl.0kxm]\n", f); fclose(f);
        f = fopen(umain, "wb"); fputs("unread\tun red\ngloopy\tglue pea\ntabindex\ttab dex\n", f); fclose(f);
        f = fopen(uabbr, "wb"); fputs("QZX\tquiz ex\n", f); fclose(f);
        plain = ev_voice_open(1);
        withu = ev_voice_open(1);
        ev_voice_preset_params(plain, &vp);
        ev_dict_configure(NULL, NULL, NULL);                 /* community OFF */
        ev_dict_configure_user(umain, uroot, uabbr);
        b = say(withu, "unread", vp, 0, &rc); free(b.pcm);
        ev_voice_dict_report(withu, &r);
        CHECK(r.in_force && r.user_added == 4, "community off, user entries in force: %d whole-word/abbreviation entries taken", r.user_added);
        {
            static const char *w[] = { "unread", "Unread", "the unread messages", "gloopy", "Gloops", "QZX" };
            int i, changed = 0;
            for (i = 0; i < 6; i++) {
                b = say(withu, w[i], vp, 0, &rc); free(b.pcm);
                strncpy(after, phonemes(withu, w[i]), sizeof after - 1); after[sizeof after - 1] = 0;
                strncpy(before, phonemes(plain, w[i]), sizeof before - 1); before[sizeof before - 1] = 0;
                if (strcmp(before, after)) changed++;
                printf("     %-20s without: %-36s with: %s%s\n", w[i], before, after, strcmp(before, after) ? "   CHANGED" : "");
            }
            CHECK(changed == 6, "user entries change %d of 6 (whole word, also capitalised and in a sentence; root in any case and inflected; abbreviation)", changed);
        }
        /* an edit reaches the next utterance */
        strncpy(before, phonemes(withu, "unread"), sizeof before - 1); before[sizeof before - 1] = 0;
        {
            char tmp[620];
            snprintf(tmp, sizeof tmp, "%s.tmp", umain);
            f = fopen(tmp, "wb"); fputs("unread\tun reed\ngloopy\tglue pea\ntabindex\ttab dex\n", f); fclose(f);
            rename(tmp, umain);
        }
        ev_dict_configure_user(umain, uroot, uabbr);
        b = say(withu, "unread", vp, 0, &rc); free(b.pcm);
        strncpy(after, phonemes(withu, "unread"), sizeof after - 1); after[sizeof after - 1] = 0;
        CHECK(strcmp(before, after) != 0, "an edited entry is heard on the next utterance: %s -> %s", before, after);
        if (dir) {
            /* against the community files: the user's whole word replaces the community one with the same key */
            char cword[512];
            snprintf(cmain, sizeof cmain, "%s/ENUmain.dic", dir);
            snprintf(croot, sizeof croot, "%s/ENURoot.dic", dir);
            snprintf(cabbr, sizeof cabbr, "%s/ENUabbr.dic", dir);
            ev_dict_configure(cmain, croot, cabbr);
            ev_dict_configure_user(NULL, NULL, NULL);
            b = say(withu, "tabindex", vp, 0, &rc); free(b.pcm);
            strncpy(cword, phonemes(withu, "tabindex"), sizeof cword - 1); cword[sizeof cword - 1] = 0;
            ev_dict_configure_user(umain, uroot, uabbr);
            b = say(withu, "tabindex", vp, 0, &rc); free(b.pcm);
            strncpy(after, phonemes(withu, "tabindex"), sizeof after - 1); after[sizeof after - 1] = 0;
            ev_voice_dict_report(withu, &r);
            CHECK(r.main_rc == 0 && strcmp(cword, after) != 0,
                  "the user's tabindex wins over the community one: %s -> %s", cword, after);
            ev_dict_configure(NULL, NULL, NULL);
        }
        ev_dict_configure_user(NULL, NULL, NULL);
        b = say(withu, "unread", vp, 0, &rc); free(b.pcm);
        strncpy(after, phonemes(withu, "unread"), sizeof after - 1); after[sizeof after - 1] = 0;
        strncpy(before, phonemes(plain, "unread"), sizeof before - 1); before[sizeof before - 1] = 0;
        ev_voice_dict_report(withu, &r);
        CHECK(!r.in_force && strcmp(before, after) == 0, "user entries off: unread is back to %s", after);
        remove(umain); remove(uroot); remove(uabbr); rmdir(udir);
        ev_voice_close(plain);
        ev_voice_close(withu);
    }

    /* 4. backquote voice tags, through ev_voice_speak (fresh handles for every render, so each is an
       instance's first utterance and renders compare byte for byte). */
    {
        ev_voice_params vp;
        ev_voice *v;
        buf_t off, off_plain, on, plain_off, plain_on;
        int peak_off = 0, peak_on = 0, i;
        v = ev_voice_open(1); ev_voice_preset_params(v, &vp); ev_voice_close(v);
        vp.speed = EV_STANDARD_SPEED;
#define FRESH(var, text) do { v = ev_voice_open(1); var = say(v, text, vp, 0, &rc); ev_voice_close(v); } while (0)
        ev_set_voice_tags(0);
        FRESH(off, "hello `vv20 world");
        FRESH(off_plain, "hello  vv20 world");
        FRESH(plain_off, sentence);
        CHECK(off.n == off_plain.n && off.n > 0 && memcmp(off.pcm, off_plain.pcm, (size_t)off.n * 2) == 0,
              "tags off: `vv20 is spoken exactly as the text with a space for the backtick (%d frames), the voice untouched", off.n);
        ev_set_voice_tags(1);
        FRESH(on, "hello `vv20 world");
        { buf_t quiet, loud; int pq = 0, pl = 0, k;
          FRESH(quiet, "`vv20 hello world");
          FRESH(loud, "hello world");
          for (k = 0; k < quiet.n; k++) if (abs(quiet.pcm[k]) > pq) pq = abs(quiet.pcm[k]);
          for (k = 0; k < loud.n; k++) if (abs(loud.pcm[k]) > pl) pl = abs(loud.pcm[k]);
          CHECK(pq > 0 && pq * 3 < pl, "tags on: `vv20 turns the volume down: peak %d vs %d", pq, pl);
          free(quiet.pcm); free(loud.pcm); }
        FRESH(plain_on, sentence);
        for (i = 0; i < off.n; i++) if (abs(off.pcm[i]) > peak_off) peak_off = abs(off.pcm[i]);
        for (i = 0; i < on.n; i++) if (abs(on.pcm[i]) > peak_on) peak_on = abs(on.pcm[i]);
        CHECK(on.n > 0 && on.n < off.n,
              "tags on: `vv20 is obeyed, not read out: %d frames vs %d (peaks %d, %d)", on.n, off.n, peak_on, peak_off);
        CHECK(plain_on.n == plain_off.n && memcmp(plain_on.pcm, plain_off.pcm, (size_t)plain_on.n * 2) == 0,
              "tags on: text with no backtick is byte-identical to tags off (%d frames)", plain_on.n);
        /* a `ts1 (spell) in one utterance does not stick to the next on the same pooled handle */
        /* ReLoq C keeps an inline `ts inside its utterance (the instance's eciTextMode never moves), so the
           check is by the audio: spelled differs, and the next utterance is the same as on a handle that
           never spelled (both an instance's SECOND utterance, which is what a pooled handle speaks). */
        { ev_voice *w = ev_voice_open(1);
          buf_t sp, after, ref0, ref;
          v = ev_voice_open(1);
          sp = say(v, "`ts1 abc", vp, 0, &rc);
          after = say(v, "abc", vp, 0, &rc);
          ref0 = say(w, "x", vp, 0, &rc);
          ref = say(w, "abc", vp, 0, &rc);
          CHECK(sp.n != after.n && after.n == ref.n && memcmp(after.pcm, ref.pcm, (size_t)ref.n * 2) == 0,
                "tags on: `ts1 took effect (%d frames spelled vs %d) and did not stick to the next utterance (%d = %d)",
                sp.n, after.n, after.n, ref.n);
          free(sp.pcm); free(after.pcm); free(ref0.pcm); free(ref.pcm);
          ev_voice_close(v); ev_voice_close(w); }
        /* off again on a handle that had annotations on: back to plain input */
        ev_set_voice_tags(0);
        v = ev_voice_open(1);
        { buf_t b = say(v, "x", vp, 0, &rc); free(b.pcm); }
        ev_set_voice_tags(1);
        { buf_t b = say(v, "x", vp, 0, &rc); free(b.pcm); }
        i = eciGetParam(v->h, eciInputType);
        ev_set_voice_tags(0);
        { buf_t b = say(v, "x", vp, 0, &rc); free(b.pcm); }
        CHECK(i == 1 && eciGetParam(v->h, eciInputType) == 0, "input type follows the switch on a pooled handle: on %d, off %d", i, eciGetParam(v->h, eciInputType));
        ev_voice_close(v);
#undef FRESH
        free(off.pcm); free(off_plain.pcm); free(on.pcm); free(plain_off.pcm); free(plain_on.pcm);
    }

    /* 5. every language, through the bridge as the extension drives it (UTF-8 in) */
    {
        static const struct { int32_t lang; const char *name; const char *text; } L[] = {
            { EV_LANG_ENUS, "enus", "Hello, this is Reed." },
            { EV_LANG_ENGB, "engb", "Hello, this is the colour of the theatre." },
            { EV_LANG_ESES, "eses", "Hola, son las cinco y media." },
            { EV_LANG_ESUS, "esus", "Hola, \xc2\xbf" "c\xc3\xb3mo est\xc3\xa1s?" },
            { EV_LANG_FRFR, "frfr", "Bonjour, \xc3\xa7" "a va? Cinq euros: 5 \xe2\x82\xac." },
            { EV_LANG_FRCA, "frca", "Bonjour, il est cinq heures." },
            { EV_LANG_DEDE, "dede", "Guten Tag, Gr\xc3\xbc\xc3\x9f" "e aus K\xc3\xb6ln." },
            { EV_LANG_ITIT, "itit", "Buongiorno, come stai?" },
            { EV_LANG_PLPL, "plpl", "Dzie\xc5\x84 dobry, jak si\xc4\x99 masz?" },
            { EV_LANG_JAJP, "jajp", "\xe3\x81\x93\xe3\x82\x93\xe3\x81\xab\xe3\x81\xa1\xe3\x81\xaf" },
            /* ReLoq C's own (its nvda/test_eci_additional_languages_native.py texts, and the app's samples) */
            { EV_LANG_PTBR, "ptbr", "Ol\xc3\xa1, S\xc3\xa3o Paulo! A informa\xc3\xa7\xc3\xa3o (nova) - f\xc3\xa1" "cil." },
            { EV_LANG_FIFI, "fifi", "Hyv\xc3\xa4\xc3\xa4 p\xc3\xa4iv\xc3\xa4\xc3\xa4! Avaa tiedosto." },
            { EV_LANG_ELGR, "elgr", "\xce\x93\xce\xb5\xce\xb9\xce\xb1 \xcf\x83\xce\xb1\xcf\x82, \xcf\x84\xce\xb9 \xce\xba\xce\xac\xce\xbd\xce\xb5\xcf\x84\xce\xb5;" },
            { EV_LANG_ZHCN, "zhcn", "\xe4\xbd\xa0\xe5\xa5\xbd\xef\xbc\x8c\xe8\xbf\x99\xe6\x98\xaf\xe4\xb8\xad\xe6\x96\x87\xe7\x9a\x84\xe5\xa3\xb0\xe9\x9f\xb3\xe3\x80\x82" },
            { EV_LANG_KOKR, "kokr", "\xec\x95\x88\xeb\x85\x95\xed\x95\x98\xec\x84\xb8\xec\x9a\x94. \xed\x95\x9c\xea\xb5\xad\xec\x96\xb4 \xeb\xaa\xa9\xec\x86\x8c\xeb\xa6\xac\xec\x9e\x85\xeb\x8b\x88\xeb\x8b\xa4." },
        };
        int k, p, tried = 0;
        for (k = 0; k < (int)(sizeof L / sizeof L[0]); k++) {
            int ok = 1, n1 = 0;
            char names[256] = "";
            if (ev_lang_index(L[k].lang) < 0) continue;     /* not this engine's (Polish on ReLoq; the new five on openevv) */
            tried++;
            for (p = 1; p <= 8; p++) {
                ev_voice *v = ev_voice_open_lang(p, L[k].lang);
                ev_voice_params vp;
                buf_t b;
                char nm[64];
                if (!v) { ok = 0; break; }
                ev_voice_preset_params(v, &vp);
                ev_voice_engine_name(v, nm, sizeof nm);
                if (p <= 2) { strncat(names, nm, sizeof names - strlen(names) - 3); strcat(names, "; "); }
                b = say(v, L[k].text, vp, 0, &rc);
                if (rc != 0 || b.n < 2000) ok = 0;
                if (p == 1) n1 = b.n;
                free(b.pcm);
                ev_voice_close(v);
            }
            CHECK(ok, "%s: all 8 presets speak the sample (%d frames for voice 1; %s...)", L[k].name, n1, names);
        }
        CHECK(tried == ev_lang_count(), "every language of this engine has a sample (%d of %d)", tried, ev_lang_count());
    }

    /* 6. per-language user entries, and the Listen marker's skip */
    {
        char udir[512], umain[600];
        const char *tmpdir = getenv("TMPDIR");
        ev_voice *de, *en;
        ev_voice_params vp;
        buf_t b;
        char base_de[512], with_de[512], en_after[512], skip_de[512];
        FILE *f;
        snprintf(udir, sizeof udir, "%s/ev-lang-dict-test-%d", tmpdir && *tmpdir ? tmpdir : "/tmp", (int)getpid());
        mkdir(udir, 0700);
        snprintf(umain, sizeof umain, "%s/user-main.dic", udir);
        f = fopen(umain, "wb"); fputs("Haus\tMaus\n", f); fclose(f);
        de = ev_voice_open_lang(1, EV_LANG_DEDE);
        en = ev_voice_open_lang(1, EV_LANG_ENUS);
        ev_voice_preset_params(de, &vp);
        b = say(de, "Haus", vp, 0, &rc); free(b.pcm);
        strncpy(base_de, phonemes(de, "Haus"), sizeof base_de - 1); base_de[sizeof base_de - 1] = 0;
        ev_dict_configure_user_lang(EV_LANG_DEDE, umain, NULL, NULL);
        b = say(de, "Haus", vp, 0, &rc); free(b.pcm);
        strncpy(with_de, phonemes(de, "Haus"), sizeof with_de - 1); with_de[sizeof with_de - 1] = 0;
        b = say(en, "Haus", vp, 0, &rc); free(b.pcm);
        strncpy(en_after, phonemes(en, "Haus"), sizeof en_after - 1); en_after[sizeof en_after - 1] = 0;
        CHECK(strcmp(base_de, with_de) != 0 && ev_dict_user_entries_lang(EV_LANG_DEDE) == 1 && ev_dict_user_entries_lang(EV_LANG_ENUS) == 0,
              "a German user entry changes German (%s -> %s) and is not in English (%s)", base_de, with_de, en_after);
        ev_dict_set_listen(EV_LANG_DEDE, "haus", 0);
        b = say(de, "Haus", vp, 0, &rc); free(b.pcm);
        strncpy(skip_de, phonemes(de, "Haus"), sizeof skip_de - 1); skip_de[sizeof skip_de - 1] = 0;
        ev_dict_set_listen(EV_LANG_DEDE, NULL, 0);
        b = say(de, "Haus", vp, 0, &rc); free(b.pcm);
        CHECK(strcmp(skip_de, base_de) == 0 && strcmp(phonemes(de, "Haus"), with_de) == 0,
              "Listen skip: the word said without the entry (%s), then with it again", skip_de);
        ev_dict_configure_user_lang(EV_LANG_DEDE, NULL, NULL, NULL);
        if (dir) {
            /* the German community files (DEU*.dic, v26.09) in the German slot only */
            char m[1024], r[1024], a[1024], before[512];
            snprintf(m, sizeof m, "%s/DEUmain.dic", dir); snprintf(r, sizeof r, "%s/DEURoot.dic", dir);
            snprintf(a, sizeof a, "%s/DEUabbr.dic", dir);
            if (access(m, R_OK) == 0) {
                ev_dict_report rep;
                b = say(de, "Armin", vp, 0, &rc); free(b.pcm);
                strncpy(before, phonemes(de, "Armin"), sizeof before - 1); before[sizeof before - 1] = 0;
                ev_dict_configure_lang(EV_LANG_DEDE, m, r, a);
                b = say(de, "Armin", vp, 0, &rc); free(b.pcm);
                ev_voice_dict_report(de, &rep);
                CHECK(rep.main_rc == 0 && rep.abbr_rc == 0 && strcmp(before, phonemes(de, "Armin")) != 0,
                      "German community files load in the German voice: Armin %s -> %s", before, phonemes(de, "Armin"));
                ev_dict_configure_lang(EV_LANG_DEDE, NULL, NULL, NULL);
            } else {
                printf("     (no DEU files in DICT_DIR: German community check skipped)\n");
            }
        }
        remove(umain); rmdir(udir);
        ev_voice_close(de); ev_voice_close(en);
    }

    /* 6. phrase prediction (ev_set_phrase_prediction): upstream openevv issue 41's sentence, which IBM's
       engine (and ours with prediction on) pauses in after "syllables". Fresh handles compare byte for
       byte; a POOLED handle switched between utterances must sound like a fresh one made with the new
       value (it is remade), and keep the user's dictionary entries. */
    {
        const char *s41 = "world wide web is three syllables but luckily they abbreviated it to 9";
        char udir[512], umain[600], with[512], after[512];
        const char *tmpdir = getenv("TMPDIR");
        ev_voice_params vp;
        ev_voice *v;
        buf_t first, on, off, pooled_off, pooled_on, comma_on, comma_off;
        FILE *f;
        CHECK(ev_phrase_prediction() == 1, "phrase prediction is on by default");
        v = ev_voice_open(1); ev_voice_preset_params(v, &vp); ev_voice_close(v);
        vp.speed = EV_STANDARD_SPEED;
#define FRESH(var, text) do { v = ev_voice_open(1); var = say(v, text, vp, 0, &rc); ev_voice_close(v); } while (0)
        FRESH(first, s41);
        ev_set_phrase_prediction(1); FRESH(on, s41); FRESH(comma_on, "Paris, France");
        ev_set_phrase_prediction(0); FRESH(off, s41); FRESH(comma_off, "Paris, France");
        CHECK(on.n == first.n && memcmp(on.pcm, first.pcm, (size_t)on.n * 2) == 0,
              "prediction on is the engine's default output: %d frames, byte-identical", on.n);
        CHECK(off.n > 0 && off.n < on.n,
              "prediction off drops the guessed pause in issue 41's sentence: %d frames vs %d on (%.0f ms shorter)",
              off.n, on.n, (on.n - off.n) * 1000.0 / EV_NATIVE_SAMPLE_RATE);
        CHECK(comma_off.n > comma_on.n,
              "prediction off pauses at the comma in \"Paris, France\": %d frames vs %d on", comma_off.n, comma_on.n);
        /* one pooled handle, the switch flipped between utterances, with a user entry in force */
        snprintf(udir, sizeof udir, "%s/ev-pp-test-%d", tmpdir && *tmpdir ? tmpdir : "/tmp", (int)getpid());
        mkdir(udir, 0700);
        snprintf(umain, sizeof umain, "%s/user-main.dic", udir);
        f = fopen(umain, "wb"); fputs("gloopy\tglue pea\n", f); fclose(f);
        ev_dict_configure(NULL, NULL, NULL);
        ev_dict_configure_user(umain, NULL, NULL);
        ev_set_phrase_prediction(1);
        v = ev_voice_open(1);
        { buf_t b = say(v, "gloopy", vp, 0, &rc); free(b.pcm); }
        strncpy(with, phonemes(v, "gloopy"), sizeof with - 1); with[sizeof with - 1] = 0;
        ev_set_phrase_prediction(0);
        pooled_off = say(v, s41, vp, 0, &rc);
        strncpy(after, phonemes(v, "gloopy"), sizeof after - 1); after[sizeof after - 1] = 0;
        CHECK(pooled_off.n == off.n && memcmp(pooled_off.pcm, off.pcm, (size_t)off.n * 2) == 0,
              "switched off on a pooled handle: the next utterance is the fresh off render (%d frames)", pooled_off.n);
        CHECK(strcmp(with, after) == 0 && strcmp(after, "") != 0,
              "the user's entry survives the remade instance: gloopy %s -> %s", with, after);
        ev_set_phrase_prediction(1);
        pooled_on = say(v, s41, vp, 0, &rc);
        CHECK(pooled_on.n == on.n && memcmp(pooled_on.pcm, on.pcm, (size_t)on.n * 2) == 0,
              "switched back on on the same handle: the fresh on render again (%d frames)", pooled_on.n);
        ev_voice_close(v);
        ev_dict_configure_user(NULL, NULL, NULL);
        remove(umain); rmdir(udir);
#undef FRESH
        free(first.pcm); free(on.pcm); free(off.pcm); free(pooled_off.pcm); free(pooled_on.pcm);
        free(comma_on.pcm); free(comma_off.pcm);
    }

    /* 9. the tone controls (ReLoq C's equaliser and Mellow mode; ev_set_tone). At the defaults the engine is never
       told anything; Bright changes the sound and not the length; back at the defaults is byte for byte the
       first render; a change is heard on the NEXT utterance of a handle already in use; Mellow changes 22050 Hz. */
    if (ev_tone_available() && ev_engine_present()) {
        ev_voice_params vp;
        ev_voice *v;
        buf_t flat, bright, back, a, b, c, f22, m22, f11, m11;
        v = ev_voice_open(1); ev_voice_preset_params(v, &vp); ev_voice_close(v);
        vp.speed = EV_STANDARD_SPEED;
#define FRESH_AT(var, hz) do { v = ev_voice_open(1); var = say_at(v, sentence, vp, hz, &rc); ev_voice_close(v); } while (0)
        ev_set_tone(0, 0, 0, 0);
        FRESH_AT(flat, 11025);
        ev_set_tone(-1, 0, 4, 0);
        FRESH_AT(bright, 11025);
        ev_set_tone(0, 0, 0, 0);
        FRESH_AT(back, 11025);
        CHECK(bright.n == flat.n && flat.n > 0 && !same_pcm(bright, flat),
              "tone Bright: the same length (%d frames), a different sound", bright.n);
        CHECK(same_pcm(back, flat), "tone back at the defaults: byte for byte the first render (%d frames)", back.n);
        v = ev_voice_open(1);
        a = say_at(v, sentence, vp, 11025, &rc);
        ev_set_tone(0, 0, 6, 0);
        b = say_at(v, sentence, vp, 11025, &rc);
        ev_set_tone(0, 0, 0, 0);
        c = say_at(v, sentence, vp, 11025, &rc);
        ev_voice_close(v);
        CHECK(b.n == a.n && !same_pcm(a, b) && same_pcm(a, c),
              "tone on a handle in use: treble +6 is heard on its next utterance, and the defaults after it again");
        FRESH_AT(f22, 22050);
        ev_set_tone(0, 0, 0, 1);
        FRESH_AT(m22, 22050);
        FRESH_AT(m11, 11025);
        ev_set_tone(0, 0, 0, 0);
        FRESH_AT(f11, 11025);
        CHECK(m22.n == f22.n && f22.n > 0 && !same_pcm(m22, f22), "tone Mellow at 22050 Hz: the same length (%d frames), a different sound", m22.n);
        CHECK(same_pcm(m11, f11), "tone Mellow at 11025 Hz: no change (ReLoq: from 16 kHz up)");
        free(flat.pcm); free(bright.pcm); free(back.pcm); free(a.pcm); free(b.pcm); free(c.pcm);
        free(f22.pcm); free(m22.pcm); free(f11.pcm); free(m11.pcm);
    }

    /* 10. "Shorten pauses" (ReLoq C's RELOQ_ECI_PAUSE_MODE; ev_set_pause_mode). The default (0) is the engine's own
       output byte for byte; Always (2) makes a comma-heavy sentence shorter; Only at end of text (1) lies between;
       and on ONE handle kept open, as VoiceOver keeps its audio unit, a change is heard on the next utterance. */
    if (ev_pause_mode_available() && ev_engine_present()) {
        const char *commas = "Red, orange, yellow, green, blue, indigo, violet, black, white, and grey, all of them, please.";
        ev_voice_params vp;
        ev_voice *v;
        buf_t first, never, end, always, a, b, c;
        CHECK(ev_pause_mode() == 0, "shorten pauses is Never by default");
        v = ev_voice_open(1); ev_voice_preset_params(v, &vp); ev_voice_close(v);
        vp.speed = EV_STANDARD_SPEED;
#define FRESH_PM(var) do { v = ev_voice_open(1); var = say(v, commas, vp, 0, &rc); ev_voice_close(v); } while (0)
        FRESH_PM(first);
        ev_set_pause_mode(0); FRESH_PM(never);
        ev_set_pause_mode(1); FRESH_PM(end);
        ev_set_pause_mode(2); FRESH_PM(always);
        ev_set_pause_mode(0);
        CHECK(same_pcm(never, first), "shorten pauses Never: the engine's own output, byte for byte (%d frames)", never.n);
        CHECK(always.n > 0 && always.n < never.n,
              "shorten pauses Always: %d frames vs %d Never (%.0f ms shorter)",
              always.n, never.n, (never.n - always.n) * 1000.0 / EV_NATIVE_SAMPLE_RATE);
        CHECK(end.n > 0 && end.n <= never.n && end.n >= always.n,
              "shorten pauses Only at end of text: %d frames, between Always and Never (%.0f ms shorter than Never)",
              end.n, (never.n - end.n) * 1000.0 / EV_NATIVE_SAMPLE_RATE);
        v = ev_voice_open(1);
        a = say(v, commas, vp, 0, &rc);
        ev_set_pause_mode(2);
        b = say(v, commas, vp, 0, &rc);
        ev_set_pause_mode(0);
        c = say(v, commas, vp, 0, &rc);
        ev_voice_close(v);
        CHECK(same_pcm(a, never) && same_pcm(b, always) && same_pcm(c, never),
              "shorten pauses on a handle in use: Always heard on its next utterance (%d frames), Never again after it (%d)",
              b.n, c.n);
#undef FRESH_PM
        free(first.pcm); free(never.pcm); free(end.pcm); free(always.pcm); free(a.pcm); free(b.pcm); free(c.pcm);
    }

    printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
