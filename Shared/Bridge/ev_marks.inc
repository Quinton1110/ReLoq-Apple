/*
 * ev_marks.inc - openevv's text pre-pass (src/eci/api/evv_marks.c), carried over unchanged in substance for
 * ReLoq C, included by ev_bridge.c. Every function below is openevv's own (fix/junction-pauses@81820b8, the
 * file's history: 440669a, 499d7d6, 88e0ef3 and the fix/punctuation-textmode commits before them; MIT, ours),
 * renamed with mk_ so nothing collides with the bridge. Written by Quinton Williams for openevv under its MIT
 * licence (NOTICE); here under this repository's GPL-3.0-or-later. What it does and what was measured for each rule is in
 * the comment at the head of that file and in openevv docs/notes/{lone-marks,glued-digits,spelling}.md.
 *
 * Why it is here: openevv runs this inside the engine, on US English text in its default reading mode, before
 * IBM's rules see it. ReLoq C does not have it, and without it ReLoq reads "the km game" as "the kilometers game",
 * spells "server.log" and the name part of an e-mail address, says "tho" as "thoe", phrases "prob" as the end
 * of a clause and reads "no5" / "Ste4" as words (measured 2026-11-19). Changes to openevv's code, each marked
 * "ReLoq:" where it is:
 *   - "an hr ago" / "a hr" stay "hour" (ReLoq's reading, kept on purpose; openevv spelled it on purpose):
 *     "a" or "an" before "hr" or "hrs" makes it the unit; every other unit after "a" is spelled as in openevv;
 *   - mk_rewrite gains a first step, mk_mail: "name@host.domain" gets a space either side of the @, which is
 *     how ReLoq reads the name part as a word ("support at apple dot com", openevv's reading). openevv needed
 *     no rule for addresses: IBM's rules read them.
 * It runs only where openevv ran it: US English (openevv's mode_cell has enus alone), the mode the text is in
 * (0 unless a `ts annotation in the text changes it - only possible with voice tags on).
 * Generated from openevv's file by a script; keep it a copy, not a rewrite.
 */

static int mk_is_space(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r'
        || c == '\f' || c == '\v';
}

static int mk_is_alnum(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9');
}

static int mk_is_digit(char c)
{
    return c >= '0' && c <= '9';
}

static int mk_is_alpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int mk_is_mark(char c, int mode)
{
    if (strchr(".,;:!?", c) != 0)
        return c != 0;
    if (mode == 3)
        return 0;
    return c != 0 && strchr("()[]{}\"", c) != 0;
}

/* A token made of nothing but marks, and not one of the three faces. */
static int mk_mark_run(const char *t, size_t n, int mode)
{
    size_t i;

    if (n == 0)
        return 0;
    for (i = 0; i < n; i++)
        if (!mk_is_mark(t[i], mode))
            return 0;
    if (n == 2 && (memcmp(t, ":)", 2) == 0 || memcmp(t, ";)", 2) == 0
                   || memcmp(t, ":(", 2) == 0))
        return 0;
    return 1;
}

/* An opening bracket, and any more of them or double quotes after it:
   `(', `((', `("'. */
static int mk_opening_run(const char *t, size_t n)
{
    size_t i;

    if (n == 0 || t[0] == 0 || strchr("([{", t[0]) == 0)
        return 0;
    for (i = 1; i < n; i++)
        if (strchr("([{\"", t[i]) == 0 || t[i] == 0)
            return 0;
    return 1;
}

/* What may stand between an opening bracket and the word it opens and go
   with the bracket to that word: more brackets and double quotes. */
static int mk_opener_tail(const char *t, size_t n)
{
    size_t i;

    if (n == 0)
        return 0;
    for (i = 0; i < n; i++)
        if (strchr("([{\"", t[i]) == 0 || t[i] == 0)
            return 0;
    return 1;
}

static int mk_has_paren(const char *t, size_t n)
{
    return memchr(t, '(', n) != 0;
}

static int mk_all_dots(const char *t, size_t n)
{
    size_t i;

    for (i = 0; i < n; i++)
        if (t[i] != '.')
            return 0;
    return 1;
}

static int mk_has_backtick(const char *t, size_t n)
{
    return memchr(t, '`', n) != 0;
}

/* A `ts annotation in the token sets the mode from there on. */
static int mk_mode_after(const char *t, size_t n, int mode)
{
    size_t i;

    for (i = 0; i + 3 < n; i++)
        if (t[i] == '`' && t[i + 1] == 't' && t[i + 2] == 's'
            && t[i + 3] >= '0' && t[i + 3] <= '3')
            mode = t[i + 3] - '0';
    return mode;
}

/* Letter runs left glued to the digits after them. Every word of two
   letters or more with a small letter in it that the rules' eng_abbr,
   eng_tok_dict and eng_cur_dict hold (lang/enus/enus.dict), less the thirty
   of them measured to read in these rules parted exactly as Apple's engine
   reads them glued (`Jan5', `in2', `apt4' among them): the rest expand when
   parted and are spelled or read as a plain word by the later engine glued.
   Case matters, as it does to those dictionaries: `Dr' is kept, `dr' is not.
   Less again (2026-09-24, the spelling sweep) the 108 of them these rules
   SPELL glued -- `Feb5', `Mon5', `no5' came out letter by letter -- which are
   parted now and read expanded ("February five"), since reading the word is
   the target and not the later engine. Sorted by strcmp. */
static const char *const mk_glued_keep[] = {
    "Blvd", "Cmdr", "Cpl", "Ctrl", "Dr", "Drs", "Ft", "Hmm", "Hmmm", "Hts",
    "Hz", "Jr", "KHz", "Kbps", "Ln", "Lt", "Ltd", "MHz", "Mbps", "Md", "Mr",
    "Mrs", "Ms", "Mt", "Ng", "Pl", "Pvt", "Rd", "Sgt", "Sr", "St", "Tbs",
    "Tbsp", "bdrm", "bldg", "blks", "blvd", "bn", "bps", "cm", "cmdr", "ctrl",
    "dB", "db", "dkg", "dkl", "dkm", "dl", "dm", "ft", "gm", "hmm", "hmmm",
    "hp", "hr", "hrs", "jct", "kHz", "kW", "kWh", "kg", "km", "lb", "lbs",
    "ltd", "mHz", "mg", "mgr", "mgt", "ml", "mm", "mpg", "mph", "ms", "mtn",
    "mts", "pd", "pg", "pkg", "pp", "rd", "tbs", "tbsp", "tsp", "tsps", "vs",
    "wk", "wks",
};

/* Whole words the token dictionary holds with the digits in them. */
static const char *const mk_glued_words[] = { "Win32", "Win32s" };

/* Words read as abbreviations when a full stop follows, left as they are
   before `.,': every entry of the rules' eng_abbr (lang/enus/enus.dict)
   less the twenty-seven measured to read `X!,' as Apple's engine reads
   `X.,'. Case matters. Sorted by strcmp. */
static const char *const mk_stop_keep[] = {
    "ADF", "ADP", "AK", "AON", "AR", "ARS", "ASSOC", "ATS", "ATT", "AUD",
    "AWG", "AZ", "Ala", "Apr", "Ariz", "Ark", "Assn", "Assoc", "Attn", "Aug",
    "Av", "Ave", "BBD", "BDT", "BEF", "BHD", "BIF", "BLVD", "BMD", "BND",
    "BNT", "BOB", "BRL", "BSD", "BWP", "BZD", "Blvd", "C", "CA", "CAD", "CAL",
    "CALIF", "CHF", "CORP", "CST", "CTRL", "CVE", "Cal", "Calif", "Capt",
    "Cir", "Cmdr", "Co", "Col", "Colo", "Conn", "Corp", "Cpl", "Ctrl", "D.C",
    "DC", "DEM", "DKK", "DZD", "Dec", "Del", "Dept", "Div", "Dr", "Drs",
    "ESP", "EST", "ET", "EUR", "Esq", "F", "FF", "FIM", "FL", "FLA", "FRF",
    "Feb", "Fed", "Fla", "Fri", "Ft", "GA", "GBP", "Ga", "Gov", "HI", "Hts",
    "Hz", "IA", "IEP", "IL", "INC", "IND", "ITL", "Ia", "Ill", "Inc", "Ind",
    "Int'l", "Intl", "Jan", "Jr", "Jul", "Jun", "KHR", "KHz", "KS", "KY",
    "KYD", "Kan", "Kathe", "Kbps", "Kbyte", "Kbytes", "Ken", "Ky", "L", "LA",
    "LUF", "Ln", "Lt", "Ltd", "M.D", "MHz", "MN", "MO", "MR", "MRS", "MST",
    "MT", "Maj", "Mar", "Mass", "Mbps", "Md", "Mich", "Minn", "Mo", "Mon",
    "Mr", "Mrs", "Ms", "Mt", "N", "N.C", "N.D", "N.E", "N.H", "N.J", "N.M",
    "N.W", "N.Y", "NA", "NC", "ND", "NE", "NH", "NJ", "NLG", "NM", "NV", "NW",
    "NY", "NZ", "Nat'l", "Natl", "Nebr", "Nev", "Nov", "OK", "ONN", "Oct",
    "Okla", "Ore", "PA", "PST", "PTE", "Pa", "Ph.D", "Ph.d", "Pl", "Pvt",
    "R.I", "RI", "RUB", "Rd", "S", "S.C", "S.D", "S.E", "S.W", "SC", "SD",
    "SEK", "SIT", "ST", "Sat", "Sep", "Sept", "Sgt", "Sr", "St", "Ste", "Sun",
    "TENN", "TN", "TX", "Tbs", "Tbsp", "Tenn", "Thurs", "Tues", "USD", "UT",
    "Utd", "V", "VA", "Va", "W", "W.V", "W.Va", "WA", "WI", "WV", "WY",
    "Wash", "Wed", "Wis", "Wisc", "Wyo", "XAF", "XOF", "acct", "apt", "attn",
    "avg", "bdrm", "bldg", "blks", "blvd", "bn", "bps", "ca", "cir", "cm",
    "cmdr", "corp", "ctrl", "cu", "dB", "db", "deg", "dept", "dkg", "dkl",
    "dkm", "dl", "dm", "doz", "etc", "fed", "ft", "g", "gm", "govt", "h",
    "hp", "hr", "hrs", "hwy", "in", "int'l", "intl", "jct", "kHz", "kW",
    "kWh", "kcal", "keV", "kg", "km", "l", "lb", "lbs", "ltd", "m", "mA",
    "mHz", "mg", "mgr", "mgt", "misc", "ml", "mm", "mpg", "mph", "ms", "msec",
    "mtn", "mts", "nat'l", "natl", "neg", "nsec", "oz", "p", "pd", "pg",
    "pkg", "pp", "rad", "rd", "rec'd", "recd", "rte", "s", "tbs", "tbsp",
    "tsp", "tsps", "vs", "wk", "wkly", "wks", "yd", "yds", "yr", "yrs",
};

static int mk_cmp_word(const void *k, const void *e)
{
    return strcmp((const char *)k, *(const char *const *)e);
}

/* Whether a space goes in before t[i], a digit with a letter before it:
   the rule in the comment at the top. */
static int mk_split_before_digit(const char *t, size_t n, size_t i)
{
    size_t b = i, e = i, k, letters = 0;
    int small = 0;
    char run[32];

    while (b > 0 && (mk_is_alpha(t[b - 1]) || t[b - 1] == '\''))
        b--;
    while (b < i && t[b] == '\'')
        b++;
    for (k = b; k < i; k++) {
        if (mk_is_alpha(t[k]))
            letters++;
        if (t[k] >= 'a' && t[k] <= 'z')
            small = 1;
    }
    if (letters < 2 || !small)
        return 0;
    if (i - b < sizeof run) {
        memcpy(run, t + b, i - b);
        run[i - b] = 0;
        if (bsearch(run, mk_glued_keep, sizeof mk_glued_keep / sizeof *mk_glued_keep,
                    sizeof *mk_glued_keep, mk_cmp_word) != 0)
            return 0;
        while (e < n && mk_is_alnum(t[e]))
            e++;
        for (k = 0; k < sizeof mk_glued_words / sizeof *mk_glued_words; k++)
            if (strlen(mk_glued_words[k]) == e - b
                && memcmp(mk_glued_words[k], t + b, e - b) == 0)
                return 0;
    }
    return 1;
}

typedef struct {
    const char *ws;     /* the whitespace in front of the token */
    size_t      nws;
    const char *tok;
    size_t      ntok;
} mk_piece;

static void mk_put(char **o, const char *s, size_t n)
{
    memcpy(*o, s, n);
    *o += n;
}

/* Whether the `.' at t[i], with a `,' after it ending the token, ends a sentence the rules
   would otherwise run on through: the word before it is not an
   abbreviation (mk_stop_keep), not a single letter, and not dotted (`a.m.,',
   `U.S.,'), where the rules already read the stop as Apple's engine does. */
static int mk_stop_before_comma(const char *t, size_t i)
{
    size_t b = i, k, letters = 0;
    char run[32];

    if (i == 0 || !mk_is_alnum(t[i - 1]))
        return 0;
    while (b > 0 && (mk_is_alnum(t[b - 1]) || t[b - 1] == '\''
                     || t[b - 1] == '.'))
        b--;
    for (k = b; k < i; k++) {
        if (mk_is_alpha(t[k]))
            letters++;
        if (t[k] == '.' && letters > 0)
            return 0;
    }
    if (letters == 0)
        return 1;
    if (letters < 2)
        return 0;
    if (i - b >= sizeof run)
        return 1;
    memcpy(run, t + b, i - b);
    run[i - b] = 0;
    return bsearch(run, mk_stop_keep, sizeof mk_stop_keep / sizeof *mk_stop_keep,
                   sizeof *mk_stop_keep, mk_cmp_word) == 0;
}

/* Whether the letter run ending at t[i-1] has a small letter in it. */
static int mk_lower_before(const char *t, size_t i)
{
    while (i > 0 && mk_is_alpha(t[i - 1])) {
        if (t[i - 1] >= 'a' && t[i - 1] <= 'z')
            return 1;
        i--;
    }
    return 0;
}

/* `word(s)', `box(es)': a bracket glued to a word that only makes it plural,
   which both engines read as the plural and which is left alone. */
static int mk_plural_mark(const char *t, size_t n, size_t i)
{
    if (t[i] != '(')
        return 0;
    if (i + 3 <= n && memcmp(t + i, "(s)", 3) == 0)
        return 1;
    if (i + 4 <= n && memcmp(t + i, "(es)", 4) == 0)
        return 1;
    return 0;
}

/* Copy a word, a space after each `;' or `,' that sits between two letters
   or digits on its own, and in the default mode a space between a run of
   letters and the digits glued to it and a `!' for a sentence's `.' that a
   `,' follows. */
/* Informal clipped adverbs the rules do not know. After `you'll', `they'll'
   and the like the rules take an unknown word for the verb, so "though you'll
   prob have to do it" is phrased [though you'll PROB] [have to do it] -- a
   nuclear accent, a boundary and "have" read as a main verb, which is heard as
   "prob, have to do it". Written with a capital the same word is taken for a
   name inside the phrase instead and read exactly as before, sound for sound,
   with the phrasing of "probably". `tho' is read as "though", which is what it
   is: the rules gave it the th of "thought". */
static const char *const mk_informal_cap[] = {
    "def", "defo", "deffo", "obv", "obvs", "prob", "probs", "totes",
};

static int mk_informal_word(const char *w, size_t n)
{
    size_t k;
    for (k = 0; k < sizeof mk_informal_cap / sizeof *mk_informal_cap; k++)
        if (strlen(mk_informal_cap[k]) == n && memcmp(mk_informal_cap[k], w, n) == 0)
            return 1;
    return 0;
}

/* Three-letter words after a dot that are words and not extensions: read as
   words ("dot zip") where the rules spell them ("dot Z I P"). Anything else
   of three letters stays as the rules have it -- `txt', `mov', `wav', `pdf'
   are spelled by convention. A part that goes on past the word (a digit, a
   second dot) is not one of these. */
static int mk_dot_word(const char *t, size_t n)
{
    static const char *const words[] = {
        "app", "bin", "box", "cat", "dog", "doe", "fix", "jar", "key", "log",
        "map", "pad", "pen", "pin", "set", "tag", "web", "zip",
    };
    size_t k, len = 0;
    while (len < n && t[len] >= 'a' && t[len] <= 'z')
        len++;
    if (len != 3)
        return 0;
    for (k = len; k < n; k++)
        if (mk_is_alnum(t[k]) || t[k] == '.' || t[k] == '\'')
            return 0;
    for (k = 0; k < sizeof words / sizeof *words; k++)
        if (memcmp(words[k], t, 3) == 0)
            return 1;
    return 0;
}

/* Units of measure the rules expand wherever they stand. eng_abbr
   (lang/enus/enus.dict) says `km' is "kilometers" whatever is around it, so
   the game KM written small, `km-autofight', `the km thing' were all
   kilometers, a `dm' was decimeters and the `db' was decibels. A unit is
   read as the unit only where it is used as one (unit_use below); anywhere
   else it is written in capitals, which these rules spell: `km' is read
   "K M", as `KM' always was.

   Which: every all-small entry of eng_abbr that is a unit of measure and
   whose capitals are spelled letter by letter, measured one by one alone,
   after "the" and before a comma and a full stop. Left as they were: single
   letters (g, h, l, m, s, p) and `in', words of their own (rad, mol), the
   ones whose capitals are read as a word and not spelled (oz, deg, doz, yd,
   yds, and yr and yrs, which are "your" as often as "year"), the ones the
   rules already spell on their own and expand only after a number (cd, lx,
   sr, and eng_tok_dict's ha), and any spelled with a capital (dB, kHz, kW,
   kWh, mA, keV, Hz, MHz, Kbps, Tbsp ...), which the capital marks as a
   unit. Sorted by strcmp. */
static const char *const mk_unit_spell[] = {
    "bps", "cm", "db", "dkg", "dkl", "dkm", "dl", "dm", "ft", "gm", "hp",
    "hr", "hrs", "kcal", "kg", "km", "lb", "lbs", "mg", "ml", "mm", "mpg",
    "mph", "ms", "msec", "nsec", "tbs", "tbsp", "tsp", "tsps", "wk", "wks",
};

/* Words that count something, after which a unit is the unit: "five km", "a
   few km". Compared without regard to case. */
static const char *const mk_unit_counts[] = {
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "hundreds", "thousand", "thousands", "million", "millions", "billion",
    "billions", "dozen", "dozens", "half", "few", "several", "many",
    /* and what makes the next word a unit: "per km", "sq km" */
    "per", "sq", "sq.", "square", "cu", "cu.", "cubic",
};

static int mk_same_word(const char *a, size_t n, const char *w)
{
    size_t k;

    if (strlen(w) != n)
        return 0;
    for (k = 0; k < n; k++) {
        char c = a[k];
        if (c >= 'A' && c <= 'Z')
            c = (char)(c - 'A' + 'a');
        if (c != w[k])
            return 0;
    }
    return 1;
}

/* Whether the token before a unit makes it one: it ends in a digit (`5 km',
   `2.5 km', `1,000 km', `5-10 km') or is a word in mk_unit_counts, or ends in
   one after a hyphen (`twenty-five km'). */
#define mk_UNIT_AFTER  1   /* the token before uses what follows as a unit */
#define mk_UNIT_BEFORE 2   /* the token after is "per": `km per hour' */
#define MK_UNIT_ARTICLE 4  /* ReLoq: the token before is "a" or "an" - a unit only for "hr" and "hrs", so "an hr ago"
                              stays "an hour ago" as ReLoq reads it (kept, 2026-11-19), while "send me
                              a dm" is still "a D M" as openevv has it; openevv spelled "an hr ago" on purpose */

static int mk_unit_after(const char *t, size_t n)
{
    size_t b = n, k;

    if (n == 0 || mk_has_backtick(t, n))
        return 0;
    if (mk_is_digit(t[n - 1]))
        return 1;
    while (b > 0 && t[b - 1] != '-')
        b--;
    for (k = 0; k < sizeof mk_unit_counts / sizeof *mk_unit_counts; k++)
        if (mk_same_word(t + b, n - b, mk_unit_counts[k]))
            return 1;
    return 0;
}

static int mk_is_unit(const char *w, size_t n)
{
    char run[8];

    if (n == 0 || n >= sizeof run)
        return 0;
    memcpy(run, w, n);
    run[n] = 0;
    return bsearch(run, mk_unit_spell, sizeof mk_unit_spell / sizeof *mk_unit_spell,
                   sizeof *mk_unit_spell, mk_cmp_word) != 0;
}

/* Whether t[b..e) is a number: digits, with `.' or `,' between them. */
static int mk_number_part(const char *t, size_t b, size_t e)
{
    size_t k;

    if (b == e || !mk_is_digit(t[b]) || !mk_is_digit(t[e - 1]))
        return 0;
    for (k = b; k < e; k++)
        if (!mk_is_digit(t[k]) && !((t[k] == '.' || t[k] == ',')
                                 && mk_is_digit(t[k + 1])))
            return 0;
    return 1;
}

/* The token with each unit in it that is not used as one written in
   capitals, into up (n bytes, the same length): `km' is `KM',
   `km-autofight' is `KM-autofight', `(km)' is `(KM)', `km's' is `KM's'.
   A token is looked at only when it is words and numbers joined by hyphens,
   with brackets, quotes and sentence marks around it, so `km/h', `5km',
   `km.py', `km_x' and `km²' are left to the rules as they were. A unit is
   one where a number or a counting word stands before it (ctx mk_UNIT_AFTER,
   or a number part before it in the token: `5-km'), or "per" after it.
   Answers whether anything was written in capitals. */
static int mk_unit_letters(const char *t, size_t n, int ctx, char *up)
{
    size_t lead = 0, end = n, b, e, k;
    int prev_number = 0, any = 0, first = 1;

    while (lead < n && strchr("([{\"'", t[lead]) != 0 && t[lead] != 0)
        lead++;
    while (end > lead && strchr(".,;:!?)]}\"'", t[end - 1]) != 0
           && t[end - 1] != 0)
        end--;
    if (end - lead >= 2 && t[end - 2] == '\'' && t[end - 1] == 's')
        end -= 2;           /* `km's' */
    if (end <= lead)
        return 0;
    /* every part words or numbers, and nothing else in the core */
    for (b = lead; b < end; b = e + 1) {
        e = b;
        while (e < end && t[e] != '-')
            e++;
        if (e == b)
            return 0;
        if (!mk_number_part(t, b, e))
            for (k = b; k < e; k++)
                if (!mk_is_alpha(t[k]))
                    return 0;
        if (e == end)
            break;
    }
    memcpy(up, t, n);
    for (b = lead; b < end; b = e + 1) {
        int number;

        e = b;
        while (e < end && t[e] != '-')
            e++;
        number = mk_number_part(t, b, e);
        if (!number && mk_is_unit(t + b, e - b)
            && !(first ? (ctx & mk_UNIT_AFTER) != 0
                         || ((ctx & MK_UNIT_ARTICLE) != 0
                             && (mk_same_word(t + b, e - b, "hr") || mk_same_word(t + b, e - b, "hrs")))
                       : prev_number)
            && !(first && e == end && (ctx & mk_UNIT_BEFORE) != 0)) {
            for (k = b; k < e; k++)
                up[k] = (char)(t[k] - 'a' + 'A');
            any = 1;
        }
        prev_number = number;
        first = 0;
        if (e == end)
            break;
    }
    return any;
}

static int mk_put_word(char **o, const char *t, size_t n, int split, int mode,
                    int unit_ctx)
{
    size_t i;
    int changed = 0;
    size_t lead = 0, end;
    char up[64];

    /* `km', `the km thing': a unit not used as one is read as letters */
    if (split && mode == 0 && n < sizeof up
        && mk_unit_letters(t, n, unit_ctx, up)) {
        t = up;
        changed = 1;
    }

    /* the word itself, between any marks before and after it */
    while (lead < n && !mk_is_alnum(t[lead]) && t[lead] != '`')
        lead++;
    end = lead;
    while (end < n && t[end] >= 'a' && t[end] <= 'z')
        end++;
    if (split && mode == 0 && end > lead && (end == n || !mk_is_alnum(t[end]))
        && (lead == 0 || !mk_is_alnum(t[lead - 1]))) {
        size_t k;
        int only_marks = 1;
        for (k = end; k < n; k++)
            if (mk_is_alnum(t[k]) || t[k] == '\'' || t[k] == '`')
                only_marks = 0;
        if (only_marks && end - lead == 3 && memcmp(t + lead, "tho", 3) == 0) {
            mk_put(o, t, lead);
            mk_put(o, "though", 6);
            mk_put(o, t + end, n - end);
            return 1;
        }
    }
    /* `backup-old.zip', `john.doe', `server.log': after a dot these rules
       spell a part of three letters, as they would a file extension. Where
       the part is an ordinary word they are read "dot" and the word. */
    if (split && mode == 0) {
        size_t d = 0, k, dots = 0;
        for (k = 0; k < n; k++) {
            if (t[k] == '.') { dots++; d = k; }
            if (t[k] == '@' || t[k] == '/' || t[k] == ':' || t[k] == '`') dots = 9;
        }
        if (dots == 1 && d >= 2 && mk_is_alpha(t[d - 1]) && mk_is_alpha(t[d - 2])
            && d + 4 <= n && mk_dot_word(t + d + 1, n - d - 1)) {
            mk_put(o, t, d);
            mk_put(o, " dot ", 5);
            mk_put(o, t + d + 1, n - d - 1);
            return 1;
        }
    }
    if (split && mode == 0 && end > lead && (end == n || !mk_is_alnum(t[end]))
        && (lead == 0 || !mk_is_alnum(t[lead - 1]))) {
        size_t k;
        int only_marks = 1;
        for (k = end; k < n; k++)
            if (mk_is_alnum(t[k]) || t[k] == '\'' || t[k] == '`')
                only_marks = 0;
        if (only_marks && mk_informal_word(t + lead, end - lead)) {
            mk_put(o, t, lead);
            *(*o)++ = (char)(t[lead] - 'a' + 'A');
            t += lead + 1;
            n -= lead + 1;
            changed = 1;
        }
    }

    for (i = 0; i < n; i++) {
        if (split && mode == 0 && i > 0 && mk_is_digit(t[i])
            && mk_is_alpha(t[i - 1]) && mk_split_before_digit(t, n, i))
            *(*o)++ = ' ';
        if (split && mode == 0 && i > 1 && strchr("([{", t[i]) != 0 && t[i] != 0
            && mk_is_alpha(t[i - 1]) && mk_is_alpha(t[i - 2]) && !mk_plural_mark(t, n, i))
            *(*o)++ = ' ';
        /* `dog&cat', `fish*chips', `over~there', `this|that', `hash#tag',
           `tomorrow@9': a symbol glued after a word made the rules spell the
           word; parted from it the word is read and the symbol named, as the
           later engine reads it. `@' only before a digit, so an address is
           left to the rules. */
        if (split && mode == 0 && i > 1 && t[i] != 0
            && (strchr("&*~|#^\\", t[i]) != 0
                || (t[i] == '@' && i + 1 < n && mk_is_digit(t[i + 1])))
            && mk_is_alpha(t[i - 1]) && mk_is_alpha(t[i - 2]) && mk_lower_before(t, i))
            *(*o)++ = ' ';
        if (split && mode == 0 && t[i] == '.' && i + 2 == n && t[i + 1] == ','
            && mk_stop_before_comma(t, i)) {
            *(*o)++ = '!';
            changed = 1;
            continue;
        }
        *(*o)++ = t[i];
        if (split && i > 0 && i + 1 < n
            && (t[i] == ';' || t[i] == ',')
            && mk_is_alnum(t[i - 1]) && mk_is_alnum(t[i + 1])
            && !(t[i] == ',' && mk_is_digit(t[i - 1]) && mk_is_digit(t[i + 1])))
            *(*o)++ = ' ';
    }
    return changed;
}

static char *mk_rewrite(const char *text, int mode)
{
    size_t len, npieces = 0, i;
    mk_piece *ps;
    const char *p, *tail;
    char *out, *o;
    int any = 0;
    /* What was last written, for a mark that wants to join it. */
    int have_last = 0, last_plain = 0, last_paren = 0, last_stop = 0;
    char last_char = 0;
    int glue_next = 0;       /* an opening bracket wants the next word */
    int drop_next_ws = 0;    /* nothing written yet and a mark dropped */

    if (text == 0 || mode < 0 || mode > 3)
        return 0;
    len = strlen(text);

    /* Cut the text into whitespace and the token after it. */
    ps = (mk_piece *)malloc((len / 2 + 2) * sizeof *ps);
    if (ps == 0)
        return 0;
    p = text;
    for (;;) {
        const char *w = p;

        while (*p && mk_is_space(*p))
            p++;
        if (*p == 0) {
            tail = w;
            break;
        }
        ps[npieces].ws = w;
        ps[npieces].nws = (size_t)(p - w);
        ps[npieces].tok = p;
        while (*p && !mk_is_space(*p))
            p++;
        ps[npieces].ntok = (size_t)(p - ps[npieces].tok);
        npieces++;
    }

    /* A space may be added after each `;' or `,' split and before each digit
       parted from its letters, never more than one a character. */
    out = (char *)malloc(2 * len + 1);
    if (out == 0) {
        free(ps);
        return 0;
    }
    o = out;

    for (i = 0; i < npieces; i++) {
        const mk_piece *c = &ps[i];
        int now = mode;

        mode = mk_mode_after(c->tok, c->ntok, mode);

        if (now != 2 && !mk_has_backtick(c->tok, c->ntok)
            && mk_mark_run(c->tok, c->ntok, now)) {
            const mk_piece *n = (i + 1 < npieces) ? &ps[i + 1] : 0;
            int next_plain = n != 0 && !mk_has_backtick(n->tok, n->ntok)
                             && !mk_mark_run(n->tok, n->ntok, now);

            any = 1;
            if (mk_opening_run(c->tok, c->ntok)) {
                size_t j = i + 1;

                /* `( " hi': the quotes standing between go with the
                   bracket, and all of it to the word. */
                if (now == 0 && !next_plain)
                    while (j < npieces && !mk_has_backtick(ps[j].tok, ps[j].ntok)
                           && mk_mark_run(ps[j].tok, ps[j].ntok, now)
                           && mk_opener_tail(ps[j].tok, ps[j].ntok))
                        j++;
                if (next_plain
                    || (j > i + 1 && j < npieces
                        && !mk_has_backtick(ps[j].tok, ps[j].ntok)
                        && !mk_mark_run(ps[j].tok, ps[j].ntok, now))) {
                    if (!drop_next_ws)
                        mk_put(&o, c->ws, c->nws);
                    mk_put(&o, c->tok, c->ntok);
                    for (i++; i < j; i++)
                        mk_put(&o, ps[i].tok, ps[i].ntok);
                    i = (next_plain ? i : j) - 1;
                    drop_next_ws = 0;
                    glue_next = 1;
                    have_last = 1;
                    last_plain = 0;
                    last_paren = 0;
                    last_stop = 0;
                    last_char = c->tok[c->ntok - 1];
                } else if (now == 0 && have_last && last_plain && !last_stop
                           && !last_paren && mk_has_paren(c->tok, c->ntok)) {
                    /* A parenthesis that opens nothing, after a word: read
                       as the comma it is in the later engine, `a (' as
                       `a,'. */
                    mk_put(&o, ",", 1);
                    last_char = ',';
                    last_stop = 1;
                } else if (!have_last) {
                    drop_next_ws = 1;
                }
            } else if (have_last && last_plain
                       && (last_stop ? mk_all_dots(c->tok, c->ntok)
                                         && last_char == '.'
                                     : !(now == 0 && last_paren))) {
                const mk_piece *n2 = (i + 1 < npieces) ? &ps[i + 1] : 0;

                mk_put(&o, c->tok, c->ntok);
                /* `x . y': a full stop on its own ends the sentence in the
                   later engine whatever it follows, where `x.' is an
                   initial here and `Dr.' an abbreviation. A second one
                   makes it the end of a sentence in these rules too. Not
                   after a digit, where a single one already is, and not
                   where more full stops follow to make an ellipsis. */
                if (now == 0 && !last_stop && c->ntok == 1
                    && c->tok[0] == '.' && mk_is_alpha(last_char)
                    && !(n2 != 0 && mk_all_dots(n2->tok, n2->ntok)))
                    mk_put(&o, ".", 1);
                last_paren = c->tok[c->ntok - 1] == ')';
                last_char = c->tok[c->ntok - 1];
                last_stop = strchr(".,;:!?", last_char) != 0;
            } else if (have_last && last_plain) {
                /* Dropped where it stands, its whitespace kept: what
                   follows is read after a wider gap, as Apple's engine
                   reads it. */
                mk_put(&o, c->ws, c->nws);
            } else if (!have_last) {
                drop_next_ws = 1;
            }
            continue;
        }

        if (!glue_next && !drop_next_ws)
            mk_put(&o, c->ws, c->nws);
        glue_next = 0;
        drop_next_ws = 0;
        if (now != 2 && !mk_has_backtick(c->tok, c->ntok)) {
            char *before = o;
            int unit_ctx = 0;

            if (i > 0 && mk_unit_after(ps[i - 1].tok, ps[i - 1].ntok))
                unit_ctx |= mk_UNIT_AFTER;
            if (i + 1 < npieces && mk_same_word(ps[i + 1].tok, ps[i + 1].ntok,
                                             "per"))
                unit_ctx |= mk_UNIT_BEFORE;
            if (i > 0 && (mk_same_word(ps[i - 1].tok, ps[i - 1].ntok, "a")
                          || mk_same_word(ps[i - 1].tok, ps[i - 1].ntok, "an")))
                unit_ctx |= MK_UNIT_ARTICLE;
            if (mk_put_word(&o, c->tok, c->ntok, 1, now, unit_ctx)
                || (size_t)(o - before) != c->ntok)
                any = 1;
        } else {
            mk_put(&o, c->tok, c->ntok);
        }
        have_last = 1;
        last_plain = !mk_has_backtick(c->tok, c->ntok);
        last_char = c->tok[c->ntok - 1];
        last_paren = last_char == ')';
        last_stop = strchr(".,;:!?", last_char) != 0;
    }
    mk_put(&o, tail, strlen(tail));
    *o = 0;
    free(ps);

    if (!any) {
        free(out);
        return 0;
    }
    return out;
}


/* ReLoq: an e-mail address keeps its name part a word. "name@host.domain" (letters, digits and . _ % + - before
   the @, a dot and two letters or more ending the host, sentence marks after it allowed) gets a space either
   side of the @: ReLoq reads "quinton @ example.com" as "quinton at example dot com", where glued it spelled
   Q U I N T O N. Measured 2026-11-19. Nothing else is touched; null = no address. */
static int mk_mail_at(const char *t, size_t n)
{
    size_t at = n, i, e = n, dot = 0, letters = 0, tail = 0;
    for (i = 0; i < n; i++) {
        if (t[i] == '`') return -1;
        if (t[i] == '@') { if (at != n) return -1; at = i; }
    }
    if (at == n || at == 0) return -1;
    for (i = 0; i < at; i++) {
        char c = t[i];
        if (mk_is_alpha(c)) letters++;
        else if (!(mk_is_digit(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-')) return -1;
    }
    if (letters == 0) return -1;
    while (e > at + 1 && strchr(".,;:!?)]}\"'", t[e - 1]) != 0 && t[e - 1] != 0) e--;
    for (i = at + 1; i < e; i++) {
        char c = t[i];
        if (c == '.') { dot = i; tail = 0; }
        else if (mk_is_alpha(c)) tail++;
        else if (!(mk_is_digit(c) || c == '-')) return -1;
    }
    if (dot == 0 || dot == at + 1 || tail < 2 || dot + 1 + tail != e) return -1;
    return (int)at;
}

static char *mk_mail(const char *text)
{
    size_t n = strlen(text), i = 0, o = 0;
    char *out = NULL;
    while (i < n) {
        size_t b = i, e;
        int at;
        while (b < n && mk_is_space(text[b])) b++;
        e = b;
        while (e < n && !mk_is_space(text[e])) e++;
        at = e > b ? mk_mail_at(text + b, e - b) : -1;
        if (at >= 0) {
            if (!out) {
                out = (char *)malloc(n + 2 * (n / 3 + 1) + 1);   /* at most one " @ " per four characters */
                if (!out) return NULL;
                memcpy(out, text, b);
                o = b;
            } else {
                memcpy(out + o, text + i, b - i);
                o += b - i;
            }
            memcpy(out + o, text + b, (size_t)at); o += (size_t)at;
            memcpy(out + o, " @ ", 3); o += 3;
            memcpy(out + o, text + b + at + 1, e - b - (size_t)at - 1); o += e - b - (size_t)at - 1;
        } else if (out) {
            memcpy(out + o, text + i, e - i);
            o += e - i;
        }
        i = e;
    }
    if (out) out[o] = 0;
    return out;
}

/* The whole pre-pass for one text in reading mode `mode` (0 unless a `ts says otherwise): in memory the caller
   frees, or null when nothing changes. */
static char *mk_prepass(const char *text, int mode)
{
    char *mailed = mode == 0 ? mk_mail(text) : NULL;
    char *out = mk_rewrite(mailed ? mailed : text, mode);
    if (out) { free(mailed); return out; }
    return mailed;
}
