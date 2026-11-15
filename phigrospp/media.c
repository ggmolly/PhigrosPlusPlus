// decodes a song (opus in webm, or anything else android reads) into samples for an AudioClip, since the game has no
// audio decoder of its own. it runs on a thread so the game keeps drawing meanwhile
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "lauxlib.h"
#include "opus.h"
#include "phigrospp.h"

#define WAIT_US 1000  // for an output buffer of android's decoder, its input side never waits so it always has work

static const char *DECODE_MT = "phigrospp.Decode";

typedef struct {
  pthread_t thread;
  char *path;
  const char *error;
  int16_t *pcm;
  size_t samples, capacity;
  int32_t channels, rate;
  atomic_bool done, cancel;
  bool joined;
} Job;

static void append(Job *job, const uint8_t *data, size_t size) {
  size_t n = size / 2;
  if (job->samples + n > job->capacity) {
    job->capacity = (job->samples + n) * 2;
    job->pcm = realloc(job->pcm, job->capacity * 2);
  }
  memcpy(job->pcm + job->samples, data, n * 2);
  job->samples += n;
}

// decodes opus in the process with libopus: android's own decoder runs in another process and costs a call there per
// 20 ms packet, too slow for a whole song. the encoder's first pre-skip samples are dropped, as players do
static const char *opus(Job *job, AMediaExtractor *extractor, AMediaFormat *format) {
  const uint8_t *head;  // OpusHead: "OpusHead", version, channels, pre-skip (u16le)...
  size_t size;
  int error;
  if (!AMediaFormat_getBuffer(format, "csd-0", (void **)&head, &size) || size < 19 || memcmp(head, "OpusHead", 8))
    return "no opus header";
  job->channels = head[9], job->rate = 48000;
  if (job->channels > 2) return "more than 2 channels";
  OpusDecoder *decoder = opus_decoder_create(48000, job->channels, &error);
  if (!decoder) return "opus failed";
  size_t skip = (size_t)(head[10] | head[11] << 8) * job->channels;
  uint8_t *packet = malloc(1 << 16);
  int16_t *frame = malloc(5760 * 2 * sizeof *frame);  // 120 ms at 48 kHz, the longest an opus packet decodes to
  const char *why = NULL;
  for (ssize_t n; !why && !atomic_load(&job->cancel) && (n = AMediaExtractor_readSampleData(extractor, packet, 1 << 16)) >= 0;
       AMediaExtractor_advance(extractor)) {
    int got = opus_decode(decoder, packet, (opus_int32)n, frame, 5760, 0);
    if (got < 0) {
      why = "broken opus packet";
      break;
    }
    size_t samples = (size_t)got * job->channels, drop = skip < samples ? skip : samples;
    skip -= drop;
    append(job, (const uint8_t *)(frame + drop), (samples - drop) * 2);
  }
  free(packet);
  free(frame);
  opus_decoder_destroy(decoder);
  return why;
}

// any other format through android's decoder, keeping the 16-bit samples it gives
static const char *codec(Job *job, AMediaExtractor *extractor, AMediaFormat *format, const char *mime) {
  AMediaCodec *codec = AMediaCodec_createDecoderByType(mime);
  const char *error = !codec ? "no decoder"
                      : AMediaCodec_configure(codec, format, NULL, NULL, 0) || AMediaCodec_start(codec) ? "decoder failed"
                                                                                                        : NULL;
  for (bool input = true, output = true; !error && output && !atomic_load(&job->cancel);) {
    ssize_t i = input ? AMediaCodec_dequeueInputBuffer(codec, 0) : -1;
    if (i >= 0) {
      size_t size;
      uint8_t *buffer = AMediaCodec_getInputBuffer(codec, i, &size);
      ssize_t read = AMediaExtractor_readSampleData(extractor, buffer, size);
      input = read >= 0;
      AMediaCodec_queueInputBuffer(codec, i, 0, input ? read : 0, input ? AMediaExtractor_getSampleTime(extractor) : 0,
                                   input ? 0 : AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
      AMediaExtractor_advance(extractor);
    }
    AMediaCodecBufferInfo info;
    ssize_t o = AMediaCodec_dequeueOutputBuffer(codec, &info, i >= 0 ? 0 : WAIT_US);
    if (o >= 0) {
      size_t size;
      uint8_t *buffer = AMediaCodec_getOutputBuffer(codec, o, &size);
      append(job, buffer + info.offset, info.size);
      AMediaCodec_releaseOutputBuffer(codec, o, false);
      output = !(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
    } else if (o == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      // the decoder's own channel count and rate are the ones its samples have
      AMediaFormat *out = AMediaCodec_getOutputFormat(codec);
      int32_t encoding = 2;  // AudioFormat.ENCODING_PCM_16BIT
      AMediaFormat_getInt32(out, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &job->channels);
      AMediaFormat_getInt32(out, AMEDIAFORMAT_KEY_SAMPLE_RATE, &job->rate);
      AMediaFormat_getInt32(out, "pcm-encoding", &encoding);
      if (encoding != 2) error = "the decoder doesn't give 16-bit samples";
      AMediaFormat_delete(out);
    }
  }
  if (codec) {
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  return error;
}

// decodes the first audio track
static const char *run(Job *job, AMediaExtractor *extractor) {
  AMediaFormat *format = NULL;
  const char *mime = NULL;
  for (size_t i = 0, n = AMediaExtractor_getTrackCount(extractor); i < n && !mime; i++) {
    format = AMediaExtractor_getTrackFormat(extractor, i);
    if (AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime) && !strncmp(mime, "audio/", 6)) {
      AMediaExtractor_selectTrack(extractor, i);
    } else {
      mime = NULL;
      AMediaFormat_delete(format);
    }
  }
  if (!mime) return "no audio track";
  int64_t duration = 0;
  AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &job->channels);
  AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, &job->rate);
  AMediaFormat_getInt64(format, AMEDIAFORMAT_KEY_DURATION, &duration);
  job->capacity = (size_t)(duration / 1000000.0 * job->rate * job->channels) + 4096;
  job->pcm = malloc(job->capacity * 2);
  const char *error = !strcmp(mime, "audio/opus") ? opus(job, extractor, format) : codec(job, extractor, format, mime);
  AMediaFormat_delete(format);
  return error ? error : atomic_load(&job->cancel) ? "cancelled" : NULL;
}

static void *decode(void *arg) {
  Job *job = arg;
  int fd = open(job->path, O_RDONLY | O_CLOEXEC);
  struct stat st;
  if (fd < 0 || fstat(fd, &st)) {
    job->error = "can't open the file";
  } else {
    AMediaExtractor *extractor = AMediaExtractor_new();
    job->error = AMediaExtractor_setDataSourceFd(extractor, fd, 0, st.st_size) ? "unreadable file" : run(job, extractor);
    AMediaExtractor_delete(extractor);
  }
  if (fd >= 0) close(fd);
  atomic_store(&job->done, true);
  return NULL;
}

static void join(Job *job) {
  if (job->joined) return;
  pthread_join(job->thread, NULL);
  job->joined = true;
}

// decode(path) -> a job, job:poll() -> nothing while it runs, then a float[] of the interleaved samples, the channel
// count and the sample rate (once, the samples are freed then)
static int l_decode(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  Job *job = lua_newuserdatauv(L, sizeof *job, 0);
  *job = (Job){.path = strdup(path)};
  luaL_setmetatable(L, DECODE_MT);
  if (pthread_create(&job->thread, NULL, decode, job)) {
    job->joined = true;
    return luaL_error(L, "can't start decoding %s", path);
  }
  return 1;
}

static int l_poll(lua_State *L) {
  Job *job = luaL_checkudata(L, 1, DECODE_MT);
  if (!atomic_load(&job->done)) return 0;
  join(job);
  if (job->error) return luaL_error(L, "%s: %s", job->path, job->error);
  if (!job->pcm) return luaL_error(L, "%s: already polled", job->path);
  float *out = push_floats(L, job->samples);
  for (size_t i = 0; i < job->samples; i++) out[i] = job->pcm[i] / 32768.0f;
  free(job->pcm);
  job->pcm = NULL;
  lua_pushinteger(L, job->channels);
  lua_pushinteger(L, job->rate);
  return 3;
}

static int l_gc(lua_State *L) {
  Job *job = luaL_checkudata(L, 1, DECODE_MT);
  atomic_store(&job->cancel, true);
  join(job);
  free(job->pcm);
  free(job->path);
  job->pcm = NULL;
  job->path = NULL;
  return 0;
}

void open_media(lua_State *L) {
  luaL_newmetatable(L, DECODE_MT);
  lua_pushcfunction(L, l_gc);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  lua_pushcfunction(L, l_poll);
  lua_setfield(L, -2, "poll");
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  lua_pushcfunction(L, l_decode);
  lua_setfield(L, -2, "decode");
}
