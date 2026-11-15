// decoder for .phc charts (the lossless codec of chart-codec/, whose README describes the format), a port of
// web/src/player/phc.ts that writes the chart back as the json the game reads
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "phigrospp.h"

#define CTX_SIZE 65  // 6-bit magnitude tree (nodes 1..63) + sign
#define MANT_SIZE (64 * 4)
#define CAP 24
#define K 4  // timed-list kinds: speed, move, rotate, alpha
#define FLAG_K 12
#define POS_CACHE 32
#define MAX_COUNT (1 << 24)  // a list longer than this is a broken file, not a chart

// ---------------------------------------------------------------- probability layout (codec.py's channels)
typedef struct {
  int base, mant;
} Channel;

static int size;
static Channel STRUCT, RAW, TJUMP[K], DUR[K], TRAW[K], VJUMP[K][2], VAL[K][2], N_TYPE, N_TIME, N_POS, N_HOLDI,
    N_HOLDR, N_SPEED, N_FP, S_FP;
static int FLAGS, NOTE_FLAGS, N_PROBS;

static Channel chan(int nctx) {
  Channel c = {size, size + nctx * CTX_SIZE};
  size += nctx * CTX_SIZE + MANT_SIZE;
  return c;
}

// the same order as phc.ts, which decides every channel's place
static void layout(void) {
  if (size) return;
  STRUCT = chan(1);
  RAW = chan(1);
  for (int k = 0; k < K; k++) TJUMP[k] = chan(1);
  for (int k = 0; k < K; k++) DUR[k] = chan(CAP);
  for (int k = 0; k < K; k++) TRAW[k] = chan(1);
  for (int k = 0; k < K; k++) VJUMP[k][0] = chan(CAP), VJUMP[k][1] = chan(CAP);
  for (int k = 0; k < K; k++) VAL[k][0] = chan(4 * CAP * 2), VAL[k][1] = chan(4 * CAP * 2);
  N_TYPE = chan(5);
  N_TIME = chan(CAP);
  N_POS = chan(CAP);
  N_HOLDI = chan(CAP);
  N_HOLDR = chan(1);
  N_SPEED = chan(2);
  N_FP = chan(CAP);
  S_FP = chan(1);
  FLAGS = size;
  NOTE_FLAGS = FLAGS + K * FLAG_K;  // +0/1 integral hold time, +2/3 position cache hit, +8..39 cache index tree
  N_PROBS = FLAGS + K * FLAG_K + 40;
}

// ---------------------------------------------------------------- f32 helpers
static double bits_f64(uint32_t bits) {
  float f;
  memcpy(&f, &bits, 4);
  return f;
}

// rounds to f32 and gives its bits, non-finite or overflowing values give 0
static uint32_t f64_bits(double x) {
  if (!isfinite(x)) return 0;
  float f = (float)x;
  uint32_t bits;
  memcpy(&bits, &f, 4);
  return (bits & 0x7f800000) == 0x7f800000 ? 0 : bits;
}

// f32 bits to an integer ordered like the float (distinct for -0 and 0), and back
static int64_t ordf(uint32_t bits) { return bits < 0x80000000u ? bits : -1 - ((int64_t)bits - 0x80000000); }
static uint32_t unordf(int64_t o) { return (uint32_t)(o >= 0 ? o : -1 - o + 0x80000000); }

static int bucket(int64_t r) {
  uint64_t x = r < 0 ? -(uint64_t)r : (uint64_t)r;
  int n = 0;
  for (; x; x >>= 1) n++;
  return n;
}

static int capped(int64_t r, int cap) { return bucket(r) < cap ? bucket(r) : cap; }

// ---------------------------------------------------------------- range decoder (LZMA-style, 16-bit adaptive probabilities)
#define PROB_ONE 65536
#define PROB_MIN 32
#define RATE_LIMIT 30
#define TOP (1u << 24)

typedef struct {
  const uint8_t *buf;
  size_t pos, size;
  uint32_t range, code;
  int32_t *probs;  // probabilities of a 0 bit, then how many times each has been updated
  bool broken;
} Decoder;

static uint8_t next_byte(Decoder *d) { return d->pos < d->size ? d->buf[d->pos++] : 0; }

static void normalize(Decoder *d) {
  while (d->range < TOP) {
    d->range <<= 8;
    d->code = (d->code << 8) | next_byte(d);
  }
}

static int bit(Decoder *d, int i) {
  int32_t p = d->probs[i], n = d->probs[N_PROBS + i];
  uint32_t bound = (d->range >> 16) * (uint32_t)p;
  int b;
  if (d->code < bound) {
    d->range = bound;
    b = 0;
  } else {
    d->code -= bound;
    d->range -= bound;
    b = 1;
  }
  normalize(d);
  int32_t delta = b == 0 ? PROB_ONE - p : -p;
  int32_t step = abs(delta) / (n + 2);
  p = delta >= 0 ? p + step : p - step;
  d->probs[i] = p < PROB_MIN ? PROB_MIN : p > PROB_ONE - PROB_MIN ? PROB_ONE - PROB_MIN : p;
  if (n < RATE_LIMIT) d->probs[N_PROBS + i] = n + 1;
  return b;
}

static int64_t direct(Decoder *d, int nbits) {
  int64_t out = 0;
  for (int k = 0; k < nbits; k++) {
    d->range >>= 1;
    int b = 0;
    if (d->code >= d->range) {
      d->code -= d->range;
      b = 1;
    }
    out = out * 2 + b;
    normalize(d);
  }
  return out;
}

// a signed residual: magnitude bucket (6-bit tree), sign, 2 adaptive mantissa bits, then raw bits
static int64_t res(Decoder *d, Channel ch, int ctx) {
  int c = ch.base + ctx * CTX_SIZE, node = 1;
  for (int k = 0; k < 6; k++) node = node * 2 + bit(d, c + node);
  int b = node - 64;
  if (b == 0) return 0;
  int neg = bit(d, c + 64), rest = b - 1, top = rest >= 2 ? 2 : rest, low = rest - top, mnode = 1;
  int64_t hi = 0;
  for (int k = 0; k < top; k++) {
    int x = bit(d, ch.mant + b * 4 + mnode);
    mnode = mnode * 2 + x;
    hi = hi * 2 + x;
  }
  int64_t lo = low > 0 ? direct(d, low) : 0;
  int64_t v = ((int64_t)1 << rest) + (hi << low) + lo;
  return neg ? -v : v;
}

static int64_t integer(Decoder *d) { return res(d, STRUCT, 0); }
static uint32_t f32bits(Decoder *d) { return unordf(res(d, RAW, 0)); }

// a list length, a broken file gives empty lists to the end and l_phc raises the error once memory is freed
static int count(Decoder *d) {
  int64_t n = integer(d);
  if (n < 0 || n > MAX_COUNT) d->broken = true;
  return d->broken ? 0 : (int)n;
}

// ---------------------------------------------------------------- timed lists (speed + judge line events)
// lagrange extrapolation at t through the last order+1 knots, in float64 (codec.py's _predict)
static double predict(const double *ht, const double *hv, int hn, double t, int order) {
  int n = order + 1;
  double s = 0;
  for (int j = hn - n; j < hn; j++) {
    double w = hv[j];
    for (int m = hn - n; m < hn; m++) {
      if (m == j) continue;
      if (ht[j] == ht[m]) return hv[hn - 1];
      w = w * ((t - ht[m]) / (ht[j] - ht[m]));
    }
    s = s + w;
  }
  return s;
}

typedef struct {
  uint32_t start, end, a, b, a2, b2;
  int shape;
} Timed;

static void decode_timed(Decoder *d, int kind, int n, Timed *out) {
  int fl = FLAGS + kind * FLAG_K;
  uint32_t prev_end = 0, prev_v[2] = {0, 0};
  int64_t prev_dur = 0;
  int tflag = 1, dflag = 1, shp = 0, dctx = 0;
  double ht[2][4] = {{0}}, hv[2][4] = {{0}}, last[2][4] = {{0}}, pr[4];
  int hn[2] = {0, 0}, vctx[2] = {0, 0}, vsign[2] = {0, 0}, jctx[2] = {0, 0}, vflag[2] = {1, 1}, seen[2] = {0, 0};
  for (int i = 0; i < n; i++) {
    Timed *ev = &out[i];
    *ev = (Timed){0};
    if (i == 0) {
      ev->start = unordf(res(d, TJUMP[kind], 0));
    } else {
      tflag = bit(d, fl + tflag);
      ev->start = tflag ? prev_end : unordf(ordf(prev_end) + res(d, TJUMP[kind], 0));
    }
    double ts = bits_f64(ev->start);
    dflag = bit(d, fl + 2 + dflag);
    if (dflag) {
      int64_t r = res(d, DUR[kind], dctx), duration = prev_dur + r;
      dctx = capped(r, CAP - 1);
      prev_dur = duration;
      ev->end = f64_bits(ts + (double)duration);
    } else {
      ev->end = unordf(ordf(ev->start) + res(d, TRAW[kind], 0));
    }
    prev_end = ev->end;
    double te = bits_f64(ev->end);
    // shape: speed events with floorPosition, judge line events with start2/end2
    shp = bit(d, fl + 4 + shp);
    ev->shape = shp;
    int nch = kind == 0 ? 1 : shp ? 2 : 1;
    for (int c = 0; c < nch; c++) {
      if (kind == 0) {
        int64_t r = res(d, VAL[kind][c], vctx[0]);
        ev->a = unordf(ordf(prev_v[0]) + r);
        vctx[0] = capped(r, CAP - 1);
        prev_v[0] = ev->a;
        continue;
      }
      int cont = 0;
      if (seen[c]) {
        cont = bit(d, fl + 6 + c * 2 + vflag[c]);
        vflag[c] = cont;
      }
      uint32_t va;
      if (cont) {
        va = prev_v[c];
      } else {
        int64_t r = res(d, VJUMP[kind][c], jctx[c]);
        va = unordf(ordf(prev_v[c]) + r);
        jctx[c] = capped(r, CAP - 1);
        hn[c] = 0;
      }
      seen[c] = 1;
      double *kt = ht[c], *kv = hv[c];
      if (hn[c] == 0) {
        kt[0] = ts;
        kv[0] = bits_f64(va);
        hn[c] = 1;
      }
      int k = hn[c];
      for (int o = 0; o < 4; o++) pr[o] = o < k ? (o > 0 ? predict(kt, kv, k, te, o) : kv[k - 1]) : pr[o - 1];
      double *errs = last[c];
      int best = 0;
      for (int o = 1; o < 4; o++)
        if (errs[o] < errs[best]) best = o;
      uint32_t pb = f64_bits(pr[best]);
      int64_t r = res(d, VAL[kind][c], (best * CAP + vctx[c]) * 2 + vsign[c]);
      uint32_t vb = unordf(ordf(pb) + r);
      vctx[c] = capped(r, CAP - 1);
      vsign[c] = r < 0;
      for (int o = 0; o < 4; o++) errs[o] = fabs((double)(ordf(vb) - ordf(f64_bits(pr[o]))));
      double y = bits_f64(vb);
      if (!(te > kt[hn[c] - 1])) {
        kt[0] = te;
        kv[0] = y;
        hn[c] = 1;
      } else {
        if (hn[c] == 4) {
          for (int m = 0; m < 3; m++) kt[m] = kt[m + 1], kv[m] = kv[m + 1];
          hn[c] = 3;
        }
        kt[hn[c]] = te;
        kv[hn[c]] = y;
        hn[c]++;
      }
      prev_v[c] = vb;
      if (c == 0) ev->a = va, ev->b = vb;
      else ev->a2 = va, ev->b2 = vb;
    }
  }
}

// ---------------------------------------------------------------- json
typedef struct {
  luaL_Buffer b;
} Json;

static void put(Json *j, const char *s) { luaL_addstring(&j->b, s); }

static void put_float(Json *j, const char *key, uint32_t bits) {
  char s[64];
  snprintf(s, sizeof s, "\"%s\":%.9g,", key, bits_f64(bits));
  put(j, s);
}

static void put_int(Json *j, const char *key, int64_t n) {
  char s[64];
  snprintf(s, sizeof s, "\"%s\":%lld,", key, (long long)n);
  put(j, s);
}

// drops the comma after the last member of an object or list
static void end(Json *j, const char *end) {
  if (luaL_bufflen(&j->b) && luaL_buffaddr(&j->b)[luaL_bufflen(&j->b) - 1] == ',') luaL_buffsub(&j->b, 1);
  put(j, end);
}

// ---------------------------------------------------------------- notes
// the line's floor position at `tick`, integrating its speed events from t = 0 (codec.py's speed_floor)
static double speed_floor(const Timed *sp, int ns, double bpm, double tick) {
  if (ns == 0) return 0;
  double t = (tick * 1.875) / bpm, fp = 0, prev_s = 0, prev_v = 0;
  for (int i = 0; i < ns; i++) {
    double s = fmax(0, (bits_f64(sp[i].start) * 1.875) / bpm);
    if (i > 0) fp += (s - prev_s) * prev_v;
    double e = (bits_f64(sp[i].end) * 1.875) / bpm, v = bits_f64(sp[i].a);
    if (e >= t || i == ns - 1) return fp + (t - s) * v;
    prev_s = s;
    prev_v = v;
  }
  return fp;
}

static void decode_notes(Json *j, Decoder *d, int n, const Timed *sp, int ns, double bpm) {
  int64_t prev_type = 0, prev_time = 0, prev_hold = 0;
  uint32_t prev_pos = 0, prev_speed[2] = {0, 0}, cache[POS_CACHE] = {0};
  int c_time = 0, c_pos = 0, c_hold = 0, c_fp = 0, ncache = 0, hit = 0;
  put(j, "[");
  for (int i = 0; i < n; i++) {
    int64_t type = prev_type + res(d, N_TYPE, prev_type < 4 ? (int)prev_type : 4);
    prev_type = type;
    int64_t r = res(d, N_TIME, c_time), time = prev_time + r;
    c_time = capped(r, CAP - 1);
    prev_time = time;
    // position: a hit in the move-to-front cache of recent positions, or a step from the previous one
    hit = ncache > 0 ? bit(d, NOTE_FLAGS + 2 + hit) : 0;
    uint32_t pos;
    int idx;
    if (hit) {
      int node = 1;
      for (int k = 0; k < 5; k++) node = node * 2 + bit(d, NOTE_FLAGS + 8 + node - 1);
      idx = node - 32;
      pos = cache[idx];
    } else {
      r = res(d, N_POS, c_pos);
      pos = unordf(ordf(prev_pos) + r);
      c_pos = capped(r, CAP - 1);
      idx = ncache < POS_CACHE ? ncache : POS_CACHE - 1;
      if (ncache < POS_CACHE) ncache++;
    }
    for (int m = idx; m > 0; m--) cache[m] = cache[m - 1];
    cache[0] = pos;
    prev_pos = pos;
    // hold time: integral ticks (holds relative to the previous hold), else raw bits
    int is_hold = type == 3;
    uint32_t hold;
    if (bit(d, NOTE_FLAGS + is_hold)) {
      r = res(d, N_HOLDI, is_hold ? c_hold : CAP - 1);
      int64_t ticks = (is_hold ? prev_hold : 0) + r;
      if (is_hold) {
        c_hold = capped(r, CAP - 2);
        prev_hold = ticks;
      }
      hold = f64_bits((double)ticks);
    } else {
      hold = unordf(res(d, N_HOLDR, 0));
    }
    uint32_t speed = unordf(ordf(prev_speed[is_hold]) + res(d, N_SPEED, is_hold));
    prev_speed[is_hold] = speed;
    uint32_t pb = f64_bits(speed_floor(sp, ns, bpm, (double)time));
    r = res(d, N_FP, c_fp);
    uint32_t fp = unordf(ordf(pb) + r);
    c_fp = capped(r, CAP - 1);
    put(j, "{");
    put_int(j, "type", type);
    put_int(j, "time", time);
    put_float(j, "positionX", pos);
    put_float(j, "holdTime", hold);
    put_float(j, "speed", speed);
    put_float(j, "floorPosition", fp);
    end(j, "},");
  }
  end(j, "]");
}

// ---------------------------------------------------------------- container
static const char *EVENT_KEYS[] = {"judgeLineMoveEvents", "judgeLineRotateEvents", "judgeLineDisappearEvents"};

typedef struct {
  int shape, sizes[6];
  uint32_t bpm;
} Head;

static void decode_chart(Json *j, Decoder *d) {
  int64_t format = integer(d);
  if (integer(d) == 1) integer(d);  // numOfNotes, the game counts the notes itself
  uint32_t offset = f32bits(d);
  int lines = count(d);
  Head *heads = calloc(lines ? lines : 1, sizeof *heads);
  for (int i = 0; i < lines; i++) {
    heads[i].shape = (int)integer(d);
    if (heads[i].shape == 1) integer(d), integer(d), integer(d);  // the line's note counts
    heads[i].bpm = f32bits(d);
    for (int k = 0; k < 6; k++) heads[i].sizes[k] = count(d);
  }
  put(j, "{");
  put_int(j, "formatVersion", format);
  put_float(j, "offset", offset);
  put(j, "\"judgeLineList\":[");
  for (int i = 0; i < lines; i++) {
    Head *h = &heads[i];
    double bpm = bits_f64(h->bpm);
    int most = 0;
    for (int k = 0; k < 6; k++) most = h->sizes[k] > most ? h->sizes[k] : most;
    Timed *sp = calloc(h->sizes[0] + 1, sizeof *sp), *ev = calloc(most + 1, sizeof *ev);
    decode_timed(d, 0, h->sizes[0], sp);
    // the rare speed floor positions, predicted from the integrated speed at the event's start
    uint32_t *floors = calloc(h->sizes[0] + 1, sizeof *floors);
    for (int e = 0; e < h->sizes[0]; e++)
      if (sp[e].shape)
        floors[e] = unordf(ordf(f64_bits(speed_floor(sp, h->sizes[0], bpm, bits_f64(sp[e].start)))) + res(d, S_FP, 0));
    put(j, "{");
    put_float(j, "bpm", h->bpm);
    put(j, "\"speedEvents\":[");
    for (int e = 0; e < h->sizes[0]; e++) {
      put(j, "{");
      put_float(j, "startTime", sp[e].start);
      put_float(j, "endTime", sp[e].end);
      put_float(j, "value", sp[e].a);
      put_float(j, "floorPosition", floors[e]);
      end(j, "},");
    }
    end(j, "],");
    put(j, "\"notesAbove\":");
    decode_notes(j, d, h->sizes[1], sp, h->sizes[0], bpm);
    put(j, ",\"notesBelow\":");
    decode_notes(j, d, h->sizes[2], sp, h->sizes[0], bpm);
    put(j, ",");
    for (int kind = 1; kind < 4; kind++) {
      int n = h->sizes[2 + kind];
      decode_timed(d, kind, n, ev);
      put(j, "\"");
      put(j, EVENT_KEYS[kind - 1]);
      put(j, "\":[");
      for (int e = 0; e < n; e++) {
        put(j, "{");
        put_float(j, "startTime", ev[e].start);
        put_float(j, "endTime", ev[e].end);
        put_float(j, "start", ev[e].a);
        put_float(j, "end", ev[e].b);
        put_float(j, "start2", ev[e].a2);
        put_float(j, "end2", ev[e].b2);
        end(j, "},");
      }
      end(j, "],");
    }
    free(sp);
    free(ev);
    free(floors);
    end(j, "},");
  }
  free(heads);
  end(j, "]}");
}

static size_t varint(const uint8_t *buf, size_t size, size_t *at) {
  size_t n = 0;
  for (int shift = 0; *at < size && shift < 64; shift += 7) {
    uint8_t b = buf[(*at)++];
    n |= (size_t)(b & 0x7f) << shift;
    if (b < 0x80) break;
  }
  return n;
}

// phc(data) -> the chart's json. modes 2 and 4 carry a patch that only restores how some numbers were written in the
// raw text, the values don't need it
static int l_phc(lua_State *L) {
  size_t n, at = 1;
  const uint8_t *data = (const uint8_t *)luaL_checklstring(L, 1, &n);
  int mode = n ? data[0] : -1;
  size_t length = n ? n - 1 : 0;
  if (mode == 2 || mode == 4) {
    length = varint(data, n, &at);
    if (length > n - at) length = n - at;
  } else if (mode != 1 && mode != 3) {
    return luaL_error(L, "unsupported .phc mode %d", mode);
  }
  layout();
  Decoder d = {data + at, 0, length, 0xffffffff, 0, calloc(2 * N_PROBS, sizeof(int32_t))};
  for (int i = 0; i < N_PROBS; i++) d.probs[i] = PROB_ONE / 2;
  for (int i = 0; i < 5; i++) d.code = (d.code << 8) | next_byte(&d);
  Json j;
  luaL_buffinit(L, &j.b);
  decode_chart(&j, &d);
  free(d.probs);
  if (d.broken) return luaL_error(L, "broken .phc file");
  luaL_pushresult(&j.b);
  return 1;
}

void open_phc(lua_State *L) {
  lua_pushcfunction(L, l_phc);
  lua_setfield(L, -2, "phc");
}
