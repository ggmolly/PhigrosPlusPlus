// android: libmain.so loads phigros++ through an added DT_NEEDED, before libil2cpp.so, which dlopen brings later
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>
#include <string.h>

#include "dobby.h"
#include "phigrospp.h"

// the linker picks the namespace of a library from the caller address, so the hooks below
// call the linker directly with the real caller instead of going through libdl
static void *(*loader_dlopen)(const char *, int, const void *);
static void *(*loader_android_dlopen_ext)(const char *, int, const void *, const void *);
static bool found;

static void loaded(const char *filename, void *handle) {
  size_t n = filename ? strlen(filename) : 0;
  if (!handle || found || n < 12 || strcmp(filename + n - 12, "libil2cpp.so")) return;
  found = true;
  found_il2cpp(handle);
}

static void *hooked_dlopen(const char *filename, int flags) {
  void *handle = loader_dlopen(filename, flags, __builtin_return_address(0));
  loaded(filename, handle);
  return handle;
}

static void *hooked_android_dlopen_ext(const char *filename, int flags, const void *info) {
  void *handle = loader_android_dlopen_ext(filename, flags, info, __builtin_return_address(0));
  loaded(filename, handle);
  return handle;
}

typedef struct {
  const char *symbol;
  void *address;
} Import;

// dlsym can't see the linker's __loader_* functions from an app, but libdl imports them: read its
// already bound GOT entries (bionic binds at load and doesn't relocate .dynamic)
static int find_import(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  Import *import = data;
  size_t n = info->dlpi_name ? strlen(info->dlpi_name) : 0;
  if (n < 9 || strcmp(info->dlpi_name + n - 9, "/libdl.so")) return 0;
  const ElfW(Dyn) *dynamic = NULL;
  const ElfW(Sym) *symbols = NULL;
  const ElfW(Rela) *relocations = NULL;
  const char *strings = NULL;
  size_t size_ = 0;
  for (int i = 0; i < info->dlpi_phnum; i++)
    if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) dynamic = (const void *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
  for (const ElfW(Dyn) *d = dynamic; d && d->d_tag != DT_NULL; d++) {
    const void *at = (const void *)(info->dlpi_addr + d->d_un.d_ptr);
    if (d->d_tag == DT_SYMTAB) symbols = at;
    else if (d->d_tag == DT_STRTAB) strings = at;
    else if (d->d_tag == DT_JMPREL) relocations = at;
    else if (d->d_tag == DT_PLTRELSZ) size_ = d->d_un.d_val;
  }
  for (size_t i = 0; symbols && strings && relocations && i < size_ / sizeof *relocations; i++)
    if (!strcmp(strings + symbols[ELF64_R_SYM(relocations[i].r_info)].st_name, import->symbol)) {
      import->address = *(void **)(info->dlpi_addr + relocations[i].r_offset);
      return 1;
    }
  return 0;
}

static void *libdl_import(const char *symbol) {
  Import import = {symbol, NULL};
  dl_iterate_phdr(find_import, &import);
  return import.address;
}

void boot_platform(char *root, size_t size) {
  char package[256] = "sh.molly.phigrosplusplus";
  FILE *f = fopen("/proc/self/cmdline", "r");
  if (f) {
    package[fread(package, 1, sizeof package - 1, f)] = 0;
    fclose(f);
  }
  char *process = strchr(package, ':');
  if (process) *process = 0;
  snprintf(root, size, "/sdcard/Android/data/%s/files/phigros++", package);
  loader_dlopen = libdl_import("__loader_dlopen");
  loader_android_dlopen_ext = libdl_import("__loader_android_dlopen_ext");
  if (!loader_dlopen || !loader_android_dlopen_ext ||
      DobbyHook(dlsym(RTLD_DEFAULT, "dlopen"), (void *)hooked_dlopen, NULL) != 0 ||
      DobbyHook(dlsym(RTLD_DEFAULT, "android_dlopen_ext"), (void *)hooked_android_dlopen_ext, NULL) != 0)
    LOGE("couldn't hook dlopen, Phigros++ is off");
}

// the android helpers are in lua, through jni (phigrospp/lua/android.lua)
void open_platform(lua_State *L) { (void)L; }

int hook_code(void *code, void *replace, void **original) {
  return DobbyHook(code, replace, (dobby_dummy_func_t *)original);
}

// hooks take effect as soon as dobby writes them
void flush_code(void) {}
