// what phigrospp.c, sync.c and bundle.c share
#pragma once
#include <android/log.h>
#include <stdbool.h>
#include <stddef.h>

#include "lua.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "phigros++", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "phigros++", __VA_ARGS__)

// the files of a bundle not read yet
typedef struct {
  const char *at, *end;
} Bundle;

void open_sync(lua_State *L);
Bundle open_bundle(lua_State *L, const char *root);
bool next_file(Bundle *b, const char **path, size_t *path_size, const char **data, size_t *size);
