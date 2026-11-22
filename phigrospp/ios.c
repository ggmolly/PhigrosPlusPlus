// ios: scripts/ipa.ts makes UnityFramework load phigros++, so it runs before il2cpp starts, and prepares the
// methods it may hook as ios forbids writing code. other methods need JIT (StikDebug, AltStore...) and dobby
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <limits.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "dobby.h"
#include "lauxlib.h"
#include "phigrospp.h"

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define PAGE 16384UL

// log.txt in the folder too: reading the system log needs a computer and a cable
static FILE *log_file;

void log_line(bool error, const char *format, ...) {
  char *line;
  va_list args;
  va_start(args, format);
  if (vasprintf(&line, format, args) >= 0) {
    os_log_with_type(OS_LOG_DEFAULT, error ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT, "%{public}s", line);
    if (log_file) fprintf(log_file, "%s%s\n", error ? "E " : "", line);
    free(line);
  }
  va_end(args);
}

// since ios 26 code the app wrote only runs in pages a debugger wrote in once. so with a debugger attached, writes
// wait in a queue until flush_code() has it write in their new pages, all in one stop
static bool attached;
static uintptr_t *written_pages;
static size_t written_count;
typedef struct {
  uint8_t *to, *bytes;
  uint32_t size;
} Write;
static Write *queue;
static size_t queued;

static bool written(uintptr_t page) {
  for (size_t i = 0; i < written_count; i++)
    if (written_pages[i] == page) return true;
  return false;
}

// through a second, writable mapping of the page, as code pages can't be made writable
static void write_code(uint8_t *to, const uint8_t *bytes, size_t size) {
  task_t task = mach_task_self();
  while (size) {
    vm_address_t page = (uintptr_t)to & ~(PAGE - 1), alias = 0;
    size_t part = size < page + PAGE - (uintptr_t)to ? size : page + PAGE - (uintptr_t)to;
    vm_prot_t current, max;
    if (vm_remap(task, &alias, PAGE, 0, VM_FLAGS_ANYWHERE, task, page, FALSE, &current, &max, VM_INHERIT_NONE) ||
        vm_protect(task, alias, PAGE, FALSE, VM_PROT_READ | VM_PROT_WRITE)) {
      LOGE("couldn't write code at %p", (void *)to);
      return;
    }
    memcpy((uint8_t *)alias + ((uintptr_t)to - page), bytes, part);
    vm_deallocate(task, alias, PAGE);
    sys_icache_invalidate(to, part);
    to += part, bytes += part, size -= part;
  }
}

// replaces dobby's own, whose way of writing code ios 26 refuses
int DobbyCodePatch(void *address, uint8_t *buffer, uint32_t size) {
  uint8_t *to = address;
  uintptr_t first = (uintptr_t)to & ~(PAGE - 1), last = (uintptr_t)(to + size - 1) & ~(PAGE - 1);
  if (!attached || (!queued && written(first) && written(last))) {
    write_code(to, buffer, size);
    return 0;
  }
  queue = realloc(queue, (queued + 1) * sizeof *queue);
  queue[queued++] = (Write){to, memcpy(malloc(size), buffer, size), size};
  return 0;
}

// the hooks scripts/ipa.ts wrote need no JIT: such a method starts with "b stub", and the stub
// (adrp x16 / ldr x16 / cbz x16 / br x16) jumps to its slot's address or, while it's 0, runs the method
static bool jit;

static uint32_t *stub_of(uint32_t *code) {
  if ((*code & 0xFC000000) != 0x14000000) return NULL;
  uint32_t *stub = code + ((int32_t)(*code << 6) >> 6);
  return (stub[0] & 0x9F00001F) == 0x90000010 && (stub[1] & 0xFFC003FF) == 0xF9400210 && stub[2] == 0xB4000050 &&
                 stub[3] == 0xD61F0200
             ? stub
             : NULL;
}

int hook_code(void *code, void *replace, void **original) {
  uint32_t *stub = stub_of(code);
  if (!stub) return jit ? DobbyHook(code, replace, (dobby_dummy_func_t *)original) : -1;
  uint64_t page = (stub[0] >> 29 & 3) | (stub[0] >> 5 & 0x7FFFF) << 2;
  uintptr_t slot = ((uintptr_t)stub & ~0xFFFUL) + ((int64_t)(page << 43) >> 31) + (stub[1] >> 10 & 0xFFF) * 8;
  if (original) *original = stub + 4;
  *(void **)slot = replace;
  return 0;
}

static bool traced(void) {
  struct kinfo_proc info = {0};
  size_t size = sizeof info;
  int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  return sysctl(name, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED);
}

void flush_code(void) {
  if (!queued) return;
  // the debugger can leave once the game started: hooks in new pages then wait for the next launch
  if (!traced()) {
    LOGE("the debugger left, %zu code writes wait for the next launch", queued);
    for (size_t i = 0; i < queued; i++) free(queue[i].bytes);
    queued = 0;
    return;
  }
  // {page, its first 8 bytes} for jit.py to write back as they are
  uint64_t (*table)[2] = malloc(2 * queued * sizeof *table);
  size_t count = 0;
  for (size_t i = 0; i < queued; i++) {
    uintptr_t pages[] = {(uintptr_t)queue[i].to & ~(PAGE - 1),
                         (uintptr_t)(queue[i].to + queue[i].size - 1) & ~(PAGE - 1)};
    for (int j = 0; j < 2; j++) {
      if (written(pages[j])) continue;
      written_pages = realloc(written_pages, (written_count + 1) * sizeof *written_pages);
      written_pages[written_count++] = pages[j];
      table[count][0] = pages[j], table[count][1] = *(uint64_t *)pages[j];
      count++;
    }
  }
  register void *x0 __asm__("x0") = table;
  register size_t x1 __asm__("x1") = count;
  __asm__ volatile("brk #0xf00d" : : "r"(x0), "r"(x1) : "memory");
  for (size_t i = 0; i < queued; i++) {
    write_code(queue[i].to, queue[i].bytes, queue[i].size);
    free(queue[i].bytes);
  }
  queued = 0;
  free(table);
}

void boot_platform(char *root, size_t size) {
  snprintf(root, size, "%s/Documents/phigros++", getenv("HOME"));
  mkdir(root, 0755);
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/log.txt", root);
  log_file = fopen(path, "w");
  if (log_file) setvbuf(log_file, NULL, _IOLBF, 0);
  uint32_t flags = 0;
  csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags);
  attached = traced();
  char version[32] = "";
  size_t length = sizeof version;
  sysctlbyname("kern.osproductversion", version, &length, NULL, 0);
  jit = (flags & CS_DEBUGGED) && (attached || atoi(version) < 26);
  found_il2cpp(RTLD_DEFAULT);
}

// thermal() -> NSProcessInfo's thermal state on android's scale (0 none, 1 light, 3 severe, 4 critical)
static int l_thermal(lua_State *L) {
  static const int android[] = {0, 1, 3, 4};
  id info = ((id(*)(Class, SEL))objc_msgSend)(objc_getClass("NSProcessInfo"), sel_registerName("processInfo"));
  long state = ((long (*)(id, SEL))objc_msgSend)(info, sel_registerName("thermalState"));
  lua_pushinteger(L, android[state & 3]);
  return 1;
}

// refreshRate() -> the screen's top rate (Hz), unity's Screen.currentResolution is stripped on ios
static int l_refresh_rate(lua_State *L) {
  id screen = ((id(*)(Class, SEL))objc_msgSend)(objc_getClass("UIScreen"), sel_registerName("mainScreen"));
  lua_pushinteger(L, ((long (*)(id, SEL))objc_msgSend)(screen, sel_registerName("maximumFramesPerSecond")));
  return 1;
}

void open_platform(lua_State *L) {
  lua_pushcfunction(L, l_thermal);
  lua_setfield(L, -2, "thermal");
  lua_pushcfunction(L, l_refresh_rate);
  lua_setfield(L, -2, "refreshRate");
}
