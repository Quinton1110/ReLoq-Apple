/*
 * ev_test.c - Mac build of the bridge exactly as the phone compiles it (the stub in this build),
 * with checks that every parameter reaches the audio. `make test` builds and runs it and writes
 * samples/stub-*.wav. Exit status non-zero on any failed check.
 */
#include "ev_bridge.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int16_t *pcm;
    int n, cap;
    int stop_after;   /* stop after this many chunks (0 = never) */
    int chunks;
} sink;

static int on_pcm(const int16_t *pcm, int n, void *user)
{
    sink *s = (sink *)user;
    if (s->n + n > s->cap) {
        s->cap = (s->n + n) * 2 + 4096;
        s->pcm = (int16_t *)realloc(s->pcm, (size_t)s->cap * sizeof *s->pcm);
    }
    memcpy(s->pcm + s->n, pcm, (size_t)n * sizeof *pcm);
    s->n += n;
    s->chunks++;
    return s->stop_after && s->chunks >= s->stop_after;
}

static double zc_hz(const sink *s, int rate)
{
    int i, c = 0;
    for (i = 1; i < s->n; i++)
        if ((s->pcm[i - 1] < 0) != (s->pcm[i] < 0)) c++;
    return s->n > 1 ? c / 2.0 / ((double)s->n / rate) : 0;
}

static int peak(const sink *s)
{
    int i, p = 0;
    for (i = 0; i < s->n; i++) if (abs(s->pcm[i]) > p) p = abs(s->pcm[i]);
    return p;
}

static void write_wav(const char *path, const sink *s, int rate)
{
    FILE *f = fopen(path, "wb");
    uint32_t data = (uint32_t)s->n * 2, u32;
    uint16_t u16;
    if (!f) return;
    fwrite("RIFF", 1, 4, f); u32 = 36 + data; fwrite(&u32, 4, 1, f); fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); u32 = 16; fwrite(&u32, 4, 1, f); u16 = 1; fwrite(&u16, 2, 1, f);
    u16 = 1; fwrite(&u16, 2, 1, f); u32 = (uint32_t)rate; fwrite(&u32, 4, 1, f);
    u32 = (uint32_t)rate * 2; fwrite(&u32, 4, 1, f); u16 = 2; fwrite(&u16, 2, 1, f); u16 = 16; fwrite(&u16, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
    fwrite(s->pcm, 2, (size_t)s->n, f);
    fclose(f);
}

static int failures;

/* stub-only helper in ev_bridge.c: the root entries the engine half would hand over for a text */
int ev_stub_root_matches(const char *text, char *out, int room);
#define CHECK(cond, ...) do { if (cond) printf("ok   " __VA_ARGS__); else { printf("FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

static sink render(ev_voice *v, const char *text, ev_request *req, int stop_after, int *rc)
{
    sink s = { 0, 0, 0, 0, 0 };
    s.stop_after = stop_after;
    *rc = ev_voice_speak(v, text, req, on_pcm, &s);
    return s;
}

int main(int argc, char **argv)
{
    const char *outdir = argc > 1 ? argv[1] : "samples";
    char path[512];
    ev_voice *v;
    ev_request base;
    int rc, i;
    sink a, b;
    double hz_a, hz_b;

    printf("engine present=%d description=\"%s\"\n", ev_engine_present(), ev_engine_description());

    /* every preset opens, reports eight values in range and a name */
    for (i = 1; i <= EV_PRESETS; i++) {
        ev_voice_params p;
        char name[64];
        v = ev_voice_open(i);
        CHECK(v != NULL, "preset %d opens", i);
        if (!v) continue;
        CHECK(ev_voice_preset_params(v, &p) == 0 && p.gender >= 0 && p.gender <= 1 && p.head_size <= 100
              && p.pitch_baseline <= 100 && p.pitch_fluctuation <= 100 && p.roughness <= 100
              && p.breathiness <= 100 && p.speed <= 250 && p.volume <= 100,
              "preset %d params: gender %d head %d pitch %d fluct %d rough %d breath %d speed %d vol %d",
              i, p.gender, p.head_size, p.pitch_baseline, p.pitch_fluctuation, p.roughness, p.breathiness,
              p.speed, p.volume);
        ev_voice_engine_name(v, name, sizeof name);
        CHECK(name[0] != 0, "preset %d name \"%s\"", i, name);
        ev_voice_close(v);
    }

    v = ev_voice_open(1);
    memset(&base, 0, sizeof base);
    ev_voice_preset_params(v, &base.voice);
    base.prosody.speed = 1; base.prosody.pitch_st = 0; base.prosody.range = 1; base.prosody.volume = 1;
    base.sample_rate = EV_NATIVE_SAMPLE_RATE;

    /* baseline */
    a = render(v, "Hello from Eloquence Voices.", &base, 0, &rc);
    hz_a = zc_hz(&a, base.sample_rate);
    CHECK(rc == 0 && a.n > 0, "baseline speaks: rc=%d frames=%d (%.3f s) zcHz=%.0f peak=%d", rc, a.n,
          (double)a.n / base.sample_rate, hz_a, peak(&a));
    snprintf(path, sizeof path, "%s/stub-reed.wav", outdir); write_wav(path, &a, base.sample_rate);

    /* empty text: no audio at all */
    b = render(v, "  ... ", &base, 0, &rc);
    CHECK(rc == 0 && b.n == 0, "text with nothing to say gives no audio: rc=%d frames=%d", rc, b.n);
    free(b.pcm);

    /* speed x2 -> about half the length */
    { ev_request r = base; r.prosody.speed = 2.0; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      CHECK(rc == 0 && fabs((double)b.n / a.n - 0.5) < 0.05, "speed x2 halves the length: %d vs %d", b.n, a.n); free(b.pcm); }

    /* Pitch shifts land in HERTZ on the engine's own dial curve (ev_pitch_hz, measured 2026-09-24),
       not as a multiple of the dial. +6 st on Reed (dial 65 = 118 Hz) -> about 167 Hz, dial ~76. The
       stub's tone follows the dial it is told, so the tone check proves the value reaches the audio. */
    { ev_request r = base; ev_voice_params told; double expect, ratio;
      r.prosody.pitch_st = 6; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      hz_b = zc_hz(&b, r.sample_rate);
      ev_apply_prosody(&r.voice, &r.prosody, &told);
      expect = 80.0 * pow(2.0, told.pitch_baseline / 40.0);
      ratio = ev_pitch_hz(told.pitch_baseline) / ev_pitch_hz(r.voice.pitch_baseline);
      CHECK(rc == 0 && fabs(ratio / pow(2.0, 6 / 12.0) - 1.0) < 0.04 && fabs(hz_b / expect - 1.0) < 0.1,
            "+6 st: dial %d -> %d = %.0f -> %.0f Hz (x%.3f, want x%.3f); tone %.0f vs expected %.0f",
            r.voice.pitch_baseline, told.pitch_baseline, ev_pitch_hz(r.voice.pitch_baseline),
            ev_pitch_hz(told.pitch_baseline), ratio, pow(2.0, 6 / 12.0), hz_b, expect); free(b.pcm); }
    /* +12 st is limited to +8 and does not pin the dial (the old mapping sent 65 x 2 = 130 -> 100) */
    { ev_voice_params told; ev_request r = base; double ratio;
      r.prosody.pitch_st = 12; ev_apply_prosody(&r.voice, &r.prosody, &told);
      ratio = ev_pitch_hz(told.pitch_baseline) / ev_pitch_hz(r.voice.pitch_baseline);
      CHECK(told.pitch_baseline < 100 && fabs(ratio / pow(2.0, EV_PITCH_UP_MAX_ST / 12.0) - 1.0) < 0.04,
            "+12 st limited to +%.0f: dial %d -> %d (x%.3f in Hz)", EV_PITCH_UP_MAX_ST, r.voice.pitch_baseline,
            told.pitch_baseline, ratio); }
    /* the curve and its inverse agree, and match the engine's own table at the measured points */
    CHECK(fabs(ev_pitch_hz(65) - 118) < 0.01 && fabs(ev_pitch_hz(81) - 203.4) < 1 && fabs(ev_pitch_dial(118) - 65) < 0.01
          && fabs(ev_pitch_dial(ev_pitch_hz(37.3)) - 37.3) < 0.01 && ev_pitch_hz(0) == 40 && ev_pitch_hz(100) == 422,
          "ev_pitch_hz: 65 -> %.0f Hz, 81 -> %.1f Hz; ev_pitch_dial(118) = %.2f", ev_pitch_hz(65), ev_pitch_hz(81),
          ev_pitch_dial(118));
    /* every preset's own dial, with VoiceOver's biggest pitch changes seen so far (+30 %%, -15 %%):
       never pinned at 100, never past the ceiling, and the shift is the asked-for one in hertz
       within one dial step (Bobby at 93 has only 2 units of headroom below the ceiling) */
    { static const int dials[8] = { 65, 81, 93, 52, 69, 89, 68, 61 };
      double up = 12 * log2(1.30), down = 12 * log2(0.85);
      int ok = 1, k; char line[512] = "";
      for (k = 0; k < 8; k++) {
          ev_voice_params vp = base.voice, hi, lo; ev_prosody pu = { 1, up, 1, 1 }, pd = { 1, down, 1, 1 };
          double rh, rl;
          vp.pitch_baseline = dials[k];
          ev_apply_prosody(&vp, &pu, &hi); ev_apply_prosody(&vp, &pd, &lo);
          rh = 12 * log2(ev_pitch_hz(hi.pitch_baseline) / ev_pitch_hz(dials[k]));
          rl = 12 * log2(ev_pitch_hz(lo.pitch_baseline) / ev_pitch_hz(dials[k]));
          if (hi.pitch_baseline > EV_PITCH_CEILING || hi.pitch_baseline <= dials[k] || lo.pitch_baseline >= dials[k]) ok = 0;
          if (hi.pitch_baseline < EV_PITCH_CEILING && fabs(rh - up) > 0.8) ok = 0;
          if (fabs(rl - down) > 0.8) ok = 0;
          snprintf(line + strlen(line), sizeof line - strlen(line), " %d->%d/%d", dials[k], hi.pitch_baseline, lo.pitch_baseline);
      }
      CHECK(ok, "presets at +30%% / -15%% (dial->up/down):%s", line); }

    /* volume x0.5 -> about half the peak */
    { ev_request r = base; r.prosody.volume = 0.5; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      CHECK(rc == 0 && fabs((double)peak(&b) / peak(&a) - 0.5) < 0.1, "volume x0.5 halves the peak: %d vs %d", peak(&b), peak(&a)); free(b.pcm); }

    /* 22050 -> twice the samples, same duration */
    { ev_request r = base; r.sample_rate = 22050; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      CHECK(rc == 0 && fabs((double)b.n / a.n - 2.0) < 0.01, "22050 Hz doubles the sample count: %d vs %d", b.n, a.n);
      snprintf(path, sizeof path, "%s/stub-reed-22050.wav", outdir); write_wav(path, &b, r.sample_rate); free(b.pcm); }

    /* the user's pitch dial: 30 instead of 65 -> lower tone */
    { ev_request r = base; r.voice.pitch_baseline = 30; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      hz_b = zc_hz(&b, r.sample_rate);
      CHECK(rc == 0 && hz_b < hz_a * 0.7, "pitch dial 30 lowers the tone: %.0f vs %.0f Hz", hz_b, hz_a); free(b.pcm); }

    /* unsupported rate refused */
    { ev_request r = base; r.sample_rate = 7000; b = render(v, "Hello", &r, 0, &rc);
      CHECK(rc == -1 && b.n == 0, "rate 7000 refused: rc=%d", rc); free(b.pcm); }

    /* stop from the callback */
    b = render(v, "Hello from Eloquence Voices, this is a longer sentence.", &base, 1, &rc);
    CHECK(rc == 1 && b.chunks == 1, "stop after the first chunk: rc=%d chunks=%d frames=%d", rc, b.chunks, b.n);
    free(b.pcm);

    /* the mapping the engine will be told */
    { ev_voice_params out; ev_prosody p = { 2.0, 12, 1.5, 0.5 };
      int want_pitch = (int)floor(ev_pitch_dial(ev_pitch_hz(65) * pow(2.0, EV_PITCH_UP_MAX_ST / 12.0)) + 0.5);
      ev_apply_prosody(&base.voice, &p, &out);
      CHECK(out.speed == 84 && out.pitch_baseline == want_pitch && out.pitch_fluctuation == 45 && out.volume == 46,
            "ev_apply_prosody: speed %d (50 + 49.6 ln 2) pitch %d fluct %d vol %d (clamped to the engine's ranges)",
            out.speed, out.pitch_baseline, out.pitch_fluctuation, out.volume); }
    /* the measured speed curve: the engine's own presets 70 and 100 land where the measurement put them */
    CHECK(ev_speed_units(50, 1.5) == 70 && ev_speed_units(50, 2.74) == 100 && ev_speed_units(50, 1.0 / 3) == 0
          && ev_speed_units(50, 7.2) == 148 && ev_speed_units(70, 1.0) == 70,
          "ev_speed_units: 1.5x -> %d, 2.74x -> %d, 1/3x -> %d, 7.2x -> %d, anchor 70 at 1x -> %d",
          ev_speed_units(50, 1.5), ev_speed_units(50, 2.74), ev_speed_units(50, 1.0 / 3), ev_speed_units(50, 7.2),
          ev_speed_units(70, 1.0));
    CHECK(fabs(ev_effective_speed(&base.voice, 7.2) - 7.2) < 0.1 && fabs(ev_effective_speed(&base.voice, 100.0) - exp(200 / 49.6)) < 1e-6,
          "effective speed: 7.2x is reachable (%.2f), 100x caps at the dial's end (%.1f)",
          ev_effective_speed(&base.voice, 7.2), ev_effective_speed(&base.voice, 100.0));
    /* a voice whose dial sits at 70 (Sandy's own preset) speaks 1.5x at factor 1 - which is why the dial
       starts at 50 for every voice and the preset's 70 is only shown */
    { ev_request r = base; r.voice.speed = 70; b = render(v, "Hello from Eloquence Voices.", &r, 0, &rc);
      CHECK(rc == 0 && fabs((double)a.n / b.n - 1.5) < 0.05, "dial 70 speaks 1.5x faster than 50: %d vs %d frames", b.n, a.n);
      free(b.pcm); }

    /* The community dictionary's file handling (the engine half's loading is checked on the Mac with
       the real engine: make engine-test). Fixture files in the shape of the real ones: Windows-1252,
       CRLF, a line with no tab, a blank line, a duplicated key (the later line wins). */
    { char mainp[600], rootp[600], abbrp[600], got[512];
      FILE *f;
      int n;
      snprintf(mainp, sizeof mainp, "%s/test-main.dic", outdir);
      snprintf(rootp, sizeof rootp, "%s/test-root.dic", outdir);
      snprintf(abbrp, sizeof abbrp, "%s/test-abbr.dic", outdir);
      f = fopen(mainp, "wb"); fputs("ios\tigh oe ess\r\nIOS\tigh oe ess\r\nno tab here\r\n\r\ntabindex\t Tab Index \r\n", f); fclose(f);
      f = fopen(rootp, "wb"); fputs("iphone\t`[.1Y.2fon]\r\nimessage\t`[.1Y.2mE.0sXJ]\r\nprot\xe9g\xe9\t`[.1pro.0tx.2Ze]\r\nipad\told\r\nipad\t`[.1Y.2pAd]\r\nmake\t`[.1mek]\r\n", f); fclose(f);
      f = fopen(abbrp, "wb"); fputs("WWII\tworld war two\r\n", f); fclose(f);
      CHECK(ev_dict_count_entries(mainp) == 3 && ev_dict_count_entries(rootp) == 6 && ev_dict_count_entries(abbrp) == 1
            && ev_dict_count_entries("/nonexistent/x.dic") == -1,
            "dictionary files parse: main %d, root %d, abbr %d entries; a missing file -> %d",
            ev_dict_count_entries(mainp), ev_dict_count_entries(rootp), ev_dict_count_entries(abbrp),
            ev_dict_count_entries("/nonexistent/x.dic"));
      ev_dict_configure(mainp, rootp, abbrp);
      n = ev_stub_root_matches("The iPhones, an iMessage's text, the iPad, PROT\xc9G\xc9, making it", got, sizeof got);
      CHECK(ev_dict_root_entries() == 5 && n == 5 && strstr(got, "iphone=`[.1Y.2fon];") && strstr(got, "imessage=")
            && strstr(got, "ipad=`[.1Y.2pAd];") && strstr(got, "prot\xe9g\xe9=") && strstr(got, "make="),
            "root table: %d entries (duplicate dropped, later wins); words -> stems found: %d", ev_dict_root_entries(), n);
      ev_dict_configure(NULL, NULL, NULL);
      CHECK(ev_dict_root_entries() == 0 && ev_stub_root_matches("iPhone", got, sizeof got) == 0,
            "configured off: no root table");
      remove(mainp); remove(rootp); remove(abbrp); }

    /* The user's own entries: a root entry of theirs wins over the community one with the same key, they
       are in force with the community files off, and an edit to the file is picked up on the next call
       (size / mtime / inode), a deleted file drops them. */
    { char rootp[600], urootp[600], umainp[600], tmp[600], got[512];
      FILE *f;
      int n;
      snprintf(rootp, sizeof rootp, "%s/test-root.dic", outdir);
      snprintf(urootp, sizeof urootp, "%s/test-user-root.dic", outdir);
      snprintf(umainp, sizeof umainp, "%s/test-user-main.dic", outdir);
      snprintf(tmp, sizeof tmp, "%s/test-user-root.tmp", outdir);
      f = fopen(rootp, "wb"); fputs("iphone	`[.1Y.2fon]\r\nunread	unreed\r\n", f); fclose(f);
      f = fopen(urootp, "wb"); fputs("unread	un-red\n", f); fclose(f);
      f = fopen(umainp, "wb"); fputs("Zoe	zoey\nzoe	zoey\n", f); fclose(f);
      ev_dict_configure(NULL, rootp, NULL);
      ev_dict_configure_user(umainp, urootp, NULL);
      n = ev_stub_root_matches("an unread iPhone", got, sizeof got);
      CHECK(n == 2 && strstr(got, "unread=un-red;") && strstr(got, "iphone=`[.1Y.2fon];") && ev_dict_user_entries() == 3,
            "user root entry wins over the community one: %s (%d user entries)", got, ev_dict_user_entries());
      ev_dict_configure(NULL, NULL, NULL);
      n = ev_stub_root_matches("an unread iPhone", got, sizeof got);
      CHECK(n == 1 && strcmp(got, "unread=un-red;") == 0, "community off, user entries still in force: %s", got);
      /* an edit written the way the app writes it: a new file renamed over the old one */
      f = fopen(tmp, "wb"); fputs("unread	un red\nuser	yooser\n", f); fclose(f);
      rename(tmp, urootp);
      ev_dict_configure_user(umainp, urootp, NULL);
      n = ev_stub_root_matches("unread users", got, sizeof got);
      CHECK(n == 2 && strstr(got, "unread=un red;") && strstr(got, "user=yooser;"), "an edit is picked up at once: %s", got);
      remove(urootp);
      ev_dict_configure_user(umainp, urootp, NULL);
      n = ev_stub_root_matches("unread users", got, sizeof got);
      CHECK(n == 0 && ev_dict_user_entries() == 2, "file removed: its entries are gone (%d left, the main file's)", ev_dict_user_entries());
      ev_dict_configure_user(NULL, NULL, NULL);
      CHECK(ev_dict_user_entries() == 0, "configured off: no user entries");
      remove(rootp); remove(umainp); }

    /* The UTF-8 fold: invisible format characters are dropped, not spaced - WhatsApp's LEFT-TO-RIGHT
       MARK in front of a name, a zero-width space or soft hyphen inside a word. */
    { char got[256];
      ev_text_fold("\xe2\x80\x8eMessage from \xe2\x80\x8eMaybe Zoe, I\xe2\x80\x99m hel\xc2\xadlo wo\xe2\x80\x8brld\xef\xbb\xbf \xe2\x81\xa6x\xe2\x81\xa9 caf\xc3\xa9",
                   got, sizeof got);
      CHECK(strcmp(got, "Message from Maybe Zoe, I'm hello world x caf\xe9") == 0, "format characters dropped: \"%s\"", got); }

    /* The Apple logo (U+F8FF, private use) is said as "Apple": spaced only where it would run into a word, so
       no double spaces (they would change the pausing), in the Windows-1252 languages and the UTF-8 ones. */
    { static const struct { const char *in, *out; } A[] = {
        { "Pay with \xef\xa3\xbf Pay", "Pay with Apple Pay" },       /* Quinton's "pay with pay", 2026-11-21 */
        { "\xef\xa3\xbfPay", "Apple Pay" },                          { "\xef\xa3\xbfWatch Series 9", "Apple Watch Series 9" },
        { "\xef\xa3\xbf", "Apple" },                                 { "Buy with \xef\xa3\xbfPay.", "Buy with Apple Pay." },
        { "(\xef\xa3\xbf)", "(Apple)" },                             { "x\xef\xa3\xbfy", "x Apple y" },
        { "\xef\xa3\xbf\xef\xa3\xbf", "Apple Apple" },               { "\xef\xa3\xbf \xef\xa3\xbf", "Apple Apple" },
        { "\xe2\x80\x8e\xef\xa3\xbf\xe2\x80\x8ePay", "Apple Pay" },  /* an LRM either side changes nothing */
        { "caf\xc3\xa9\xef\xa3\xbf", "caf\xe9 Apple" },               { "\xef\xa3\xbf\xe2\x80\x99s", "Apple's" },
      };
      char got[256]; int k, bad = 0;
      ev_set_text_prepass(0);      /* the logo alone; the US English pre-pass is checked below */
      for (k = 0; k < (int)(sizeof A / sizeof A[0]); k++) {
          ev_text_fold(A[k].in, got, sizeof got);
          if (strcmp(got, A[k].out) != 0) { bad++; printf("     logo \"%s\" -> \"%s\" (want \"%s\")\n", A[k].in, got, A[k].out); }
      }
      ev_set_text_prepass(1);
      CHECK(bad == 0, "Apple logo said as Apple: %d of %d", (int)(sizeof A / sizeof A[0]) - bad, (int)(sizeof A / sizeof A[0]));
      ev_text_fold("Pay with \xef\xa3\xbf Pay", got, sizeof got);
      CHECK(strcmp(got, "Pay with Apple Pay") == 0, "and with the US English pre-pass on: \"%s\"", got);
      ev_text_fold_lang("\xef\xa3\xbfPay \xe3\x81\xa7", EV_LANG_JAJP, got, sizeof got);
      CHECK(strcmp(got, "Apple Pay \xe3\x81\xa7") == 0, "Japanese (UTF-8 to the engine): \"%s\"", got);
      ev_text_fold_lang("\xe2\x80\x8e\xef\xa3\xbf\xe2\x80\x8ePay", EV_LANG_PLPL, got, sizeof got);
      CHECK(strcmp(got, "Apple Pay") == 0, "Polish (UTF-8), LRMs around it: \"%s\"", got);
      ev_text_fold_lang("\xef\xa3\xbf" "Pay", EV_LANG_FRFR, got, sizeof got);
      CHECK(strcmp(got, "Apple Pay") == 0, "French: \"%s\"", got); }

    /* UK English and the US community files (ev_bridge.h "UK ENGLISH AND THE US FILES"): what a UK voice gets of
       each US entry. Measured with ReLoq C 2026-11-22: the UK engine reads an annotation with the flap F or the
       glottal stop ? out as text, so those entries are left out; an unstressed R becomes the UK schwa x. */
    { static const struct { const char *in, *out; int keep; } U[] = {
        { "`[.1Y.2fon]", "`[.1Y.2fon]", 1 },                         /* iphone: the same for both */
        { "`[.1Y.2mE.0sXJ]", "`[.1Y.2mE.0sXJ]", 1 },                 /* imessage */
        { "igh oe ess", "igh oe ess", 1 },                           /* ios: a respelling, read with UK rules */
        { "`[.1fa.0DR]", "`[.1fa.0Dx]", 1 },                         /* father: unstressed R -> x */
        { "`[.2ko.1c.0TR]", "`[.2ko.1c.0Tx]", 1 },                   /* coauthor */
        { "`[.1bRd]", "`[.1bRd]", 1 },                               /* bird: a stressed R is UK's NURSE vowel too */
        { "`[.0dX.1fYl.0R]", "`[.0dX.1fYl.0x]", 1 },                 /* defiler */
        { "`[.1bE.0FR]", "", 0 },                                     /* better: the flap */
        { "`[.1par.0?N]", "", 0 },                                    /* Parton: the glottal stop */
        { "`[.1Y] `[.1o] `2 `[.1Es]", "`[.1Y] `[.1o] `2 `[.1Es]", 1 },/* several annotations, `2 between */
        { "`[.1ka.0F]x `[.1RR]", "", 0 },                             /* F in any annotation of the entry */
        { "R and F outside brackets", "R and F outside brackets", 1 },/* only annotations are phonemes */
      };
      char got[256]; int k, bad = 0;
      for (k = 0; k < (int)(sizeof U / sizeof U[0]); k++) {
          int r = ev_dict_adapt_value(EV_LANG_ENGB, U[k].in, got, sizeof got);
          if (r != U[k].keep || (r == 1 && strcmp(got, U[k].out) != 0)) {
              bad++; printf("     UK adapt \"%s\" -> %d \"%s\" (want %d \"%s\")\n", U[k].in, r, got, U[k].keep, U[k].out);
          }
      }
      CHECK(bad == 0, "UK English: %d of %d US entries adapted as the UK engine needs", (int)(sizeof U / sizeof U[0]) - bad,
            (int)(sizeof U / sizeof U[0]));
      for (k = 0, bad = 0; k < (int)(sizeof U / sizeof U[0]); k++) {
          int r = ev_dict_adapt_value(EV_LANG_ENUS, U[k].in, got, sizeof got);
          if (r != 1 || strcmp(got, U[k].in) != 0) bad++;
          r = ev_dict_adapt_value(EV_LANG_DEDE, U[k].in, got, sizeof got);
          if (r != 1 || strcmp(got, U[k].in) != 0) bad++;
      }
      CHECK(bad == 0, "US English and German take every entry exactly as written");
      CHECK(ev_dict_adapt_value(EV_LANG_ENGB, "`[.1Y.2fon]", got, 5) == -1, "a too-small buffer is refused, not cut"); }

    /* "Enable backquote voice tags": off (the default) makes every backtick a space, as NVDA's driver does */
    { char got[128];
      CHECK(ev_voice_tags() == 0, "voice tags are off by default");
      ev_set_text_prepass(0);      /* the backticks alone; the US English pre-pass is checked below */
      ev_text_fold("hello `vv20 world \xe2\x80\x98x`", got, sizeof got);
      CHECK(strcmp(got, "hello  vv20 world 'x ") == 0, "tags off: backticks become spaces: \"%s\"", got);
      ev_set_text_prepass(1);
      ev_set_voice_tags(1);
      ev_text_fold("hello `vv20 world", got, sizeof got);
      CHECK(strcmp(got, "hello `vv20 world") == 0 && ev_voice_tags() == 1, "tags on: the annotation goes through: \"%s\"", got);
      ev_set_voice_tags(0); }

    /* Text per language, as the stub routes it (ReLoq C's way, the default engine): Polish, Japanese,
       Chinese, Korean and Greek go through as UTF-8 (eciAddTextUtf8), the rest as Windows-1252 with its
       0x80-0x9F characters (euro, oe, bullet ...). Format characters drop out in all of them. */
    { char got[256];
      ev_text_fold_lang("5 \xe2\x82\xac \xc5\x93" "uvre \xe2\x80\xa2 \xe2\x80\x8ex", EV_LANG_FRFR, got, sizeof got);
      CHECK(strcmp(got, "5 \x80 \x9c" "uvre   x") == 0, "French: euro and oe as Windows-1252 bytes, a bullet still a space, LRM dropped");
      ev_text_fold_lang("Dzie\xc5\x84 \xe2\x80\x8e" "dobry", EV_LANG_PLPL, got, sizeof got);
      CHECK(strcmp(got, "Dzie\xc5\x84 dobry") == 0, "Polish: UTF-8 kept for the engine, LRM dropped: \"%s\"", got);
      ev_text_fold_lang("\xe3\x81\x93\xe3\x82\x93 \xe2\x80\x8ex", EV_LANG_JAJP, got, sizeof got);
      CHECK(strcmp(got, "\xe3\x81\x93\xe3\x82\x93 x") == 0, "Japanese: UTF-8 kept, LRM dropped");
      ev_text_fold_lang("\xce\x93\xce\xb5\xce\xb9\xce\xac `x", EV_LANG_ELGR, got, sizeof got);
      CHECK(strcmp(got, "\xce\x93\xce\xb5\xce\xb9\xce\xac  x") == 0, "Greek: UTF-8 kept, backtick neutralised");
      CHECK(ev_lang_index(EV_LANG_ENGB) == 1 && ev_lang_index(EV_LANG_ZHCN) >= 0 && ev_lang_index(EV_LANG_PLPL) >= 0
            && ev_lang_count() == 15 && ev_lang_index(0x123456) == -1 && ev_voice_open_lang(1, 0x123456) == NULL,
            "languages: the stub knows all 15 of both engines, an unknown language refused"); }

    /* openevv's US English pre-pass (ev_marks.inc), what ReLoq C is handed: each fix ReLoq lacked, the cases it
       must leave alone, and only US English */
    { static const struct { const char *in, *out; } P[] = {
        { "the km game", "the KM game" },              { "5 km", "5 km" },
        { "km per hour", "km per hour" },               { "an hr ago", "an hr ago" },
        { "the ms word", "the MS word" },               { "send me a dm", "send me a DM" },
        { "tho it works", "though it works" },
        { "you'll prob have to", "you'll Prob have to" },
        { "server.log", "server dot log" },             { "john.doe", "john dot doe" },
        { "mail quinton@example.com now", "mail quinton @ example.com now" },
        { "Feb5", "Feb 5" },                            { "Ste4", "Ste 4" },    { "no5", "no 5" },
        { "COVID19", "COVID19" },                       { "x86", "x86" },
        { "x . y", "x.. y" },                           { "Hello world.", "Hello world." },
      };
      char got[256]; int k, bad = 0;
      for (k = 0; k < (int)(sizeof P / sizeof P[0]); k++) {
          ev_text_fold(P[k].in, got, sizeof got);
          if (strcmp(got, P[k].out) != 0) { bad++; printf("     pre-pass \"%s\" -> \"%s\" (want \"%s\")\n", P[k].in, got, P[k].out); }
      }
      CHECK(bad == 0, "US English pre-pass: %d of %d as openevv rewrites them", (int)(sizeof P / sizeof P[0]) - bad, (int)(sizeof P / sizeof P[0]));
      ev_text_fold_lang("the km game", EV_LANG_ENGB, got, sizeof got);
      CHECK(strcmp(got, "the km game") == 0, "British English is not rewritten (openevv did US English only): \"%s\"", got);
      ev_set_text_prepass(0); ev_text_fold("the km game", got, sizeof got); ev_set_text_prepass(1);
      CHECK(strcmp(got, "the km game") == 0, "the pre-pass switch turns it off: \"%s\"", got); }

    /* The tone controls: flat and Mellow off by default (ReLoq's own), one packed word, clamped */
    { int b, m, t, me;
      ev_tone(&b, &m, &t, &me);
      CHECK(b == 0 && m == 0 && t == 0 && me == 0, "tone defaults flat, Mellow off: %d %d %d %d", b, m, t, me);
      ev_set_tone(-1, 0, 4, 1); ev_tone(&b, &m, &t, &me);
      CHECK(b == -1 && m == 0 && t == 4 && me == 1, "tone Bright + Mellow round-trips: %d %d %d %d", b, m, t, me);
      ev_set_tone(-30, 12, 99, 0); ev_tone(&b, &m, &t, &me);
      CHECK(b == -12 && m == 12 && t == 12 && me == 0, "tone clamps to -12..+12: %d %d %d %d", b, m, t, me);
      ev_set_tone(0, 0, 0, 0); ev_tone(&b, &m, &t, &me);
      CHECK(b == 0 && m == 0 && t == 0 && me == 0 && ev_tone_available(), "tone back to the defaults, available on the stub"); }

    /* "Shorten pauses": Never (0) by default, ReLoq's own; 0..2 round-trip; clamped */
    { int i, ok = ev_pause_mode() == 0;
      CHECK(ok, "shorten pauses defaults to Never (0): %d", ev_pause_mode());
      for (i = 0, ok = 1; i <= 2; i++) { ev_set_pause_mode(i); ok = ok && ev_pause_mode() == i; }
      CHECK(ok, "shorten pauses 0, 1, 2 round-trip");
      ev_set_pause_mode(-5); ok = ev_pause_mode() == 0; ev_set_pause_mode(9); ok = ok && ev_pause_mode() == 2;
      ev_set_pause_mode(0);
      CHECK(ok && ev_pause_mode() == 0 && ev_pause_mode_available(), "shorten pauses clamps to 0..2, back to Never, available on the stub"); }

    /* Sample rates as the stub (and ReLoq C) take them: the seven ECI codes, every one native */
    CHECK(ev_sample_rate_supported(22050) && ev_sample_rate_supported(48000) && !ev_sample_rate_supported(12000)
          && ev_sample_rate_native(16000) && !ev_sample_rate_native(9000), "rates: the seven codes, all native");

    /* phrase prediction: on by default, the switch reads back; the stub's audio ignores it (the engine
       half is measured in `make engine-test`) */
    { int was = ev_phrase_prediction();
      ev_set_phrase_prediction(0);
      b = render(v, "Hello from Eloquence Voices.", &base, 0, &rc);
      CHECK(was == 1 && ev_phrase_prediction() == 0 && rc == 0 && b.n == a.n,
            "phrase prediction: on by default, off reads back, the stub speaks the same (%d frames)", b.n);
      ev_set_phrase_prediction(1); free(b.pcm); }

    free(a.pcm);
    ev_voice_close(v);
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
