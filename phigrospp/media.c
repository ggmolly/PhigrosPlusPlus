// decodes a song (opus in webm, or anything else the system reads) into samples for an AudioClip, since the game has
// no audio decoder of its own. it runs on a thread so the game keeps drawing meanwhile
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#else
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#endif

#include "lauxlib.h"
#include "opus.h"
#include "phigrospp.h"

static const char *DECODE_MT = "phigrospp.Decode";
static const char NOT_OPUS[] = "not opus in webm";

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

static void append(Job *job, const void *data, size_t size) {
  size_t n = size / 2;
  if (job->samples + n > job->capacity) {
    job->capacity = (job->samples + n) * 2;
    job->pcm = realloc(job->pcm, job->capacity * 2);
  }
  memcpy(job->pcm + job->samples, data, n * 2);
  job->samples += n;
}

// matroska elements: the masters listed are entered, any other element is skipped
enum {
  EBML = 0x1A45DFA3, SEGMENT = 0x18538067, INFO = 0x1549A966, TRACKS = 0x1654AE6B, TRACK = 0xAE, CLUSTER = 0x1F43B675,
  GROUP = 0xA0, SCALE = 0x2AD7B1, DURATION = 0x4489, NUMBER = 0xD7, CODEC = 0x86, SIMPLE_BLOCK = 0xA3, BLOCK = 0xA1,
  PRIVATE = 0x63A2,
};

// an ebml number, its first byte's leading zeros tell its length. ids keep the length bit, sizes don't
static bool vint(const uint8_t **at, const uint8_t *end, bool id, uint64_t *value) {
  if (*at >= end || !**at) return false;
  int n = __builtin_clz(**at) - 23;
  if (end - *at < n) return false;
  *value = id ? **at : **at & (0xFF >> n);
  for (int i = 1; i < n; i++) *value = *value << 8 | (*at)[i];
  *at += n;
  return true;
}

// decodes opus in webm in the process with libopus, the system's decoder is much slower on android. the encoder's
// first pre-skip samples are dropped, as players do. NOT_OPUS for any other file
static const char *webm(Job *job, const uint8_t *at, const uint8_t *end) {
  const uint8_t *head = NULL;  // OpusHead: "OpusHead", version, channels, pre-skip (u16le)...
  uint64_t id, size, number = 0, track = 0, scale = 1000000;
  double duration = 0;  // in units of scale nanoseconds
  size_t skip = 0;
  OpusDecoder *decoder = NULL;
  int16_t frame[5760 * 2];  // 120 ms at 48 kHz, the longest an opus packet decodes to
  const char *why = NULL;
  for (bool first = true; at < end && !why && !atomic_load(&job->cancel); first = false) {
    bool read = vint(&at, end, true, &id) && vint(&at, end, false, &size);
    if (first && (!read || id != EBML)) return NOT_OPUS;
    if (!read) why = "broken webm";
    else if (id == SEGMENT || id == INFO || id == TRACKS || id == TRACK || id == CLUSTER || id == GROUP) continue;
    // also catches a leaf of unknown size, all ones
    else if (size > (uint64_t)(end - at)) why = "broken webm";
    if (why) break;
    const uint8_t *data = at, *packet = at + size;
    at = packet;
    uint64_t value = 0;  // big endian, for the numbers below
    for (const uint8_t *c = data; c < packet && size <= 8; c++) value = value << 8 | *c;
    if (id == NUMBER) {
      number = value;
    } else if (id == SCALE) {
      scale = value;
    } else if (id == DURATION && size == 4) {
      float f;
      memcpy(&f, &(uint32_t){(uint32_t)value}, 4);
      duration = f;
    } else if (id == DURATION && size == 8) {
      memcpy(&duration, &value, 8);
    } else if (id == CODEC && size == 6 && !memcmp(data, "A_OPUS", 6)) {
      track = number;
    } else if (id == PRIVATE && size >= 19 && !memcmp(data, "OpusHead", 8)) {
      head = data;
    } else if (id == SIMPLE_BLOCK || id == BLOCK) {
      if (!decoder) {
        if (!track || !head) return NOT_OPUS;
        int error;
        job->channels = head[9], job->rate = 48000;
        if (job->channels > 2) why = "more than 2 channels";
        else if (!(decoder = opus_decoder_create(48000, job->channels, &error))) why = "opus failed";
        skip = (size_t)(head[10] | head[11] << 8) * job->channels;
        job->capacity = (size_t)(duration * scale / 1e9 * 48000 + 5760) * job->channels;
        job->pcm = malloc(job->capacity * 2);
      }
      // the block's track, a 16-bit time and flags, then the packet when it isn't laced
      if (why || !vint(&data, packet, false, &number) || number != track) continue;
      if (packet - data < 3 || data[2] & 0x06) {
        why = "laced webm blocks";
        break;
      }
      data += 3;
      int got = opus_decode(decoder, data, (opus_int32)(packet - data), frame, 5760, 0);
      if (got < 0) {
        why = "broken opus packet";
        break;
      }
      size_t samples = (size_t)got * job->channels, drop = skip < samples ? skip : samples;
      skip -= drop;
      append(job, frame + drop, (samples - drop) * 2);
    }
  }
  if (decoder) opus_decoder_destroy(decoder);
  return why ? why : decoder ? NULL : "no audio";
}

#ifdef __APPLE__
// any other format through the system's decoder, as 16-bit samples
static const char *system_decode(Job *job, int fd, off_t size) {
  (void)fd, (void)size;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)job->path, strlen(job->path), false);
  ExtAudioFileRef file;
  OSStatus status = ExtAudioFileOpenURL(url, &file);
  CFRelease(url);
  if (status) return "unreadable file";
  AudioStreamBasicDescription in;
  UInt32 n = sizeof in;
  const char *why = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &n, &in) ? "unreadable file" : NULL;
  UInt32 channels = in.mChannelsPerFrame, bytes = 2 * channels;
  AudioStreamBasicDescription out = {
      .mSampleRate = in.mSampleRate, .mFormatID = kAudioFormatLinearPCM, .mChannelsPerFrame = channels,
      .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, .mBitsPerChannel = 16,
      .mFramesPerPacket = 1, .mBytesPerFrame = bytes, .mBytesPerPacket = bytes,
  };
  if (!why && ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof out, &out))
    why = "decoder failed";
  job->channels = (int32_t)channels, job->rate = (int32_t)in.mSampleRate;
  int16_t buffer[4096 * 8];
  for (UInt32 frames = 1; !why && frames && !atomic_load(&job->cancel);) {
    frames = sizeof buffer / bytes;
    AudioBufferList list = {1, {{channels, frames * bytes, buffer}}};
    if (ExtAudioFileRead(file, &frames, &list)) why = "broken audio";
    else append(job, buffer, frames * bytes);
  }
  ExtAudioFileDispose(file);
  return why;
}
#else
#define WAIT_US 1000  // for an output buffer of android's decoder, its input side never waits so it always has work

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
  const char *error = codec(job, extractor, format, mime);
  AMediaFormat_delete(format);
  return error;
}

// any other format through android's decoder, keeping the 16-bit samples it gives
static const char *system_decode(Job *job, int fd, off_t size) {
  AMediaExtractor *extractor = AMediaExtractor_new();
  const char *error = AMediaExtractor_setDataSourceFd(extractor, fd, 0, size) ? "unreadable file" : run(job, extractor);
  AMediaExtractor_delete(extractor);
  return error;
}
#endif

static void *decode(void *arg) {
  Job *job = arg;
  int fd = open(job->path, O_RDONLY | O_CLOEXEC);
  struct stat st;
  void *data = MAP_FAILED;
  if (fd < 0 || fstat(fd, &st) || (data = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0)) == MAP_FAILED) {
    job->error = "can't open the file";
  } else {
    job->error = webm(job, data, (uint8_t *)data + st.st_size);
    if (job->error == NOT_OPUS) job->error = system_decode(job, fd, st.st_size);
    if (!job->error && atomic_load(&job->cancel)) job->error = "cancelled";
  }
  if (data != MAP_FAILED) munmap(data, st.st_size);
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
