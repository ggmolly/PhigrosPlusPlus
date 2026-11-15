// what phigrospp.c and the other C files share
#pragma once
#include <stdbool.h>
#include <stddef.h>

#include "lua.h"

#ifdef __APPLE__
#define PLATFORM "ios"
void log_line(bool error, const char *format, ...) __attribute__((format(printf, 2, 3)));
#define LOGI(...) log_line(false, __VA_ARGS__)
#define LOGE(...) log_line(true, __VA_ARGS__)
#else
#include <android/log.h>
#define PLATFORM "android"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "phigros++", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "phigros++", __VA_ARGS__)
#endif

// the files of a bundle not read yet
typedef struct {
  const char *at, *end;
} Bundle;

void open_sync(lua_State *L);
void open_phc(lua_State *L);
void open_media(lua_State *L);
float *push_floats(lua_State *L, size_t n);
Bundle open_bundle(lua_State *L, const char *root);
bool next_file(Bundle *b, const char **path, size_t *path_size, const char **data, size_t *size);

// what android.c and ios.c give: boot_platform writes the phigros++ folder into root and calls found_il2cpp once the
// library holding il2cpp is loaded, open_platform adds the platform's own functions to the phigrospp table, hook_code
// makes code jump to replace (original then runs the code as it was) and flush_code makes the hooks set since its
// last call take effect
void boot_platform(char *root, size_t size);
void open_platform(lua_State *L);
int hook_code(void *code, void *replace, void **original);
void flush_code(void);
void found_il2cpp(void *handle);
