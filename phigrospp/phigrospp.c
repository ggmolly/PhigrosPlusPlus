// phigros++: lua 5.4 mod host for Phigros, loaded with libmain.so through a DT_NEEDED
// boot() waits for libil2cpp, start() hooks a per-frame method, mods run in tick() on the main thread
#include <dirent.h>
#include <dlfcn.h>
#include <link.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "dobby.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
#include "phigrospp.h"

#define IL2CPP_API(X)                                                \
  X(void *, domain_get, (void))                                      \
  X(void *, thread_attach, (void *))                                 \
  X(void *, thread_current, (void))                                  \
  X(void **, domain_get_assemblies, (void *, size_t *))              \
  X(void *, assembly_get_image, (void *))                            \
  X(size_t, image_get_class_count, (void *))                         \
  X(void *, image_get_class, (void *, size_t))                       \
  X(void *, class_from_name, (void *, const char *, const char *))   \
  X(void *, class_get_method_from_name, (void *, const char *, int)) \
  X(const char *, class_get_name, (void *))                          \
  X(const char *, class_get_namespace, (void *))                     \
  X(void *, class_get_declaring_type, (void *))                      \
  X(void *, class_get_parent, (void *))                              \
  X(void *, class_get_methods, (void *, void **))                    \
  X(void *, class_get_fields, (void *, void **))                     \
  X(void *, class_get_type, (void *))                                \
  X(void *, class_from_type, (void *))                               \
  X(bool, class_is_valuetype, (void *))                              \
  X(bool, class_is_enum, (void *))                                   \
  X(void *, class_enum_basetype, (void *))                           \
  X(int32_t, class_value_size, (void *, uint32_t *))                 \
  X(void *, class_get_element_class, (void *))                       \
  X(bool, class_is_assignable_from, (void *, void *))                \
  X(int, array_element_size, (void *))                               \
  X(int, type_get_type, (void *))                                    \
  X(char *, type_get_name, (void *))                                 \
  X(bool, type_is_byref, (void *))                                   \
  X(void *, type_get_object, (void *))                               \
  X(const char *, method_get_name, (void *))                         \
  X(uint32_t, method_get_param_count, (void *))                      \
  X(void *, method_get_param, (void *, uint32_t))                    \
  X(const char *, method_get_param_name, (void *, uint32_t))         \
  X(void *, method_get_return_type, (void *))                        \
  X(uint32_t, method_get_flags, (void *, uint32_t *))                \
  X(void *, method_get_class, (void *))                              \
  X(const char *, field_get_name, (void *))                          \
  X(size_t, field_get_offset, (void *))                              \
  X(void *, field_get_type, (void *))                                \
  X(int, field_get_flags, (void *))                                  \
  X(void *, field_get_parent, (void *))                              \
  X(void, field_static_get_value, (void *, void *))                  \
  X(void, field_static_set_value, (void *, void *))                  \
  X(void *, object_new, (void *))                                    \
  X(void *, array_new, (void *, uintptr_t))                          \
  X(void *, object_get_class, (void *))                              \
  X(void *, object_unbox, (void *))                                  \
  X(void *, object_get_virtual_method, (void *, void *))             \
  X(void *, runtime_invoke, (void *, void *, void **, void **))      \
  X(void, runtime_class_init, (void *))                              \
  X(void *, string_new_len, (const char *, uint32_t))                \
  X(uintptr_t, gchandle_new, (void *, bool))                         \
  X(void, gchandle_free, (uintptr_t))                                \
  X(void, format_exception, (void *, char *, int))                   \
  X(void, gc_wbarrier_set_field, (void *, void **, void *))          \
  X(void, free, (void *))

#define DECLARE(ret, name, args) static ret(*il2cpp_##name) args;
IL2CPP_API(DECLARE)
#undef DECLARE

// Il2CppTypeEnum
enum {
  T_VOID = 0x01, T_BOOLEAN, T_CHAR, T_I1, T_U1, T_I2, T_U2, T_I4, T_U4, T_I8, T_U8, T_R4, T_R8, T_STRING, T_PTR,
  T_BYREF, T_VALUETYPE, T_CLASS, T_VAR, T_ARRAY, T_GENERICINST, T_TYPEDBYREF, T_I = 0x18, T_U = 0x19,
  T_FNPTR = 0x1b, T_OBJECT = 0x1c, T_SZARRAY = 0x1d, T_MVAR = 0x1e,
};
#define ATTR_STATIC 0x0010
#define METHOD_VIRTUAL 0x0040
#define MAX_ERRORS 10  // a hook or event handler failing this many times gets disabled
#define HEADER 0x10  // sizeof(Il2CppObject)
#define ARRAY_LENGTH 0x18
#define ARRAY_DATA 0x20
#define STRING_LENGTH 0x10
#define STRING_CHARS 0x14

// zeroed stack memory: the il2cpp GC scans stacks, so object pointers kept here stay alive
#define SCRATCH(size) memset(alloca((size) < 8 ? 8 : (size)), 0, (size) < 8 ? 8 : (size))

#define FOR_INSTANCE_FIELDS(klass, field)                                     \
  for (void *iter_ = NULL, *field; (field = il2cpp_class_get_fields(klass, &iter_));) \
    if (!(il2cpp_field_get_flags(field) & ATTR_STATIC))

static void *domain, *string_class, *il2cpp_handle;
static pthread_mutex_t lock;
static lua_State *L;
static char root[512];
static volatile int load_pending;
// bumped on each reload so calls that started under the old lua state are ignored
static uint32_t generation = 1;

static __thread bool attached;
static void ensure_attached(void) {
  if (attached) return;
  if (!il2cpp_thread_current()) il2cpp_thread_attach(domain);
  attached = true;
}

static const char *OBJECT_MT = "il2cpp.Object";
// weak table: object address -> its userdata, so one object always gives the same userdata
static char CACHE_KEY;

typedef struct {
  void *obj;
  uintptr_t handle;  // the il2cpp GC doesn't scan the lua heap
} Object;

// the class of `type` if it's a struct or an enum, else NULL
static void *value_class(void *type) {
  int kind = il2cpp_type_get_type(type);
  if (kind != T_VALUETYPE && kind != T_GENERICINST) return NULL;
  void *klass = il2cpp_class_from_type(type);
  return il2cpp_class_is_valuetype(klass) ? klass : NULL;
}

static bool is_ref(void *type) {
  switch (il2cpp_type_get_type(type)) {
    case T_STRING: case T_CLASS: case T_OBJECT: case T_SZARRAY: case T_ARRAY: case T_VAR: case T_MVAR: return true;
    case T_GENERICINST: return !value_class(type);
    default: return false;
  }
}

static size_t type_size(void *type) {
  switch (il2cpp_type_get_type(type)) {
    case T_BOOLEAN: case T_I1: case T_U1: return 1;
    case T_CHAR: case T_I2: case T_U2: return 2;
    case T_I4: case T_U4: case T_R4: return 4;
  }
  void *klass = value_class(type);
  return klass ? (size_t)il2cpp_class_value_size(klass, NULL) : 8;
}

// writes into a managed object, through the GC write barrier for references
static void store(void *owner, void *slot, void *type, void *value) {
  if (is_ref(type)) il2cpp_gc_wbarrier_set_field(owner, slot, *(void **)value);
  else memcpy(slot, value, type_size(type));
}

static void push_string(lua_State *L, void *s) {
  int32_t n = *(int32_t *)((char *)s + STRING_LENGTH);
  const uint16_t *c = (const uint16_t *)((char *)s + STRING_CHARS);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int32_t i = 0; i < n; i++) {
    uint32_t cp = c[i];
    if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n && c[i + 1] >= 0xDC00 && c[i + 1] < 0xE000)
      cp = 0x10000 + ((cp - 0xD800) << 10) + (c[++i] - 0xDC00);  // utf-16 surrogate pair
    if (cp < 0x80) {
      luaL_addchar(&b, (char)cp);
    } else {
      lua_pushfstring(L, "%U", (long)cp);
      luaL_addvalue(&b);
    }
  }
  luaL_pushresult(&b);
}

static void new_userdata(lua_State *L, void *obj) {
  Object *o = lua_newuserdatauv(L, sizeof(Object), 0);
  o->obj = obj;
  o->handle = il2cpp_gchandle_new(obj, false);
  luaL_setmetatable(L, OBJECT_MT);
}

static void push_object(lua_State *L, void *obj) {
  if (!obj) {
    lua_pushnil(L);
    return;
  }
  if (il2cpp_object_get_class(obj) == string_class) {
    push_string(L, obj);
    return;
  }
  lua_rawgetp(L, LUA_REGISTRYINDEX, &CACHE_KEY);
  if (lua_rawgetp(L, -1, obj) != LUA_TUSERDATA) {
    lua_pop(L, 1);
    new_userdata(L, obj);
    lua_pushvalue(L, -1);
    lua_rawsetp(L, -3, obj);
  }
  lua_remove(L, -2);
}

static void *to_ptr(lua_State *L, int i) {
  switch (lua_type(L, i)) {
    case LUA_TNONE: case LUA_TNIL: return NULL;
    case LUA_TLIGHTUSERDATA: return lua_touserdata(L, i);
    case LUA_TUSERDATA: {
      Object *o = luaL_testudata(L, i, OBJECT_MT);
      if (o) return o->obj;
      break;
    }
    case LUA_TNUMBER:
      if (lua_isinteger(L, i)) return (void *)(intptr_t)lua_tointeger(L, i);
      break;
    case LUA_TSTRING: {
      size_t n;
      const char *s = lua_tolstring(L, i, &n);
      return il2cpp_string_new_len(s, (uint32_t)n);
    }
  }
  luaL_error(L, "expected an il2cpp object, got %s", luaL_typename(L, i));
  return NULL;
}

static void *check_object(lua_State *L, int i) {
  void *obj = to_ptr(L, i);
  if (!obj) luaL_error(L, "bad argument #%d (expected an il2cpp object, got nil)", i);
  return obj;
}

static void *check_light(lua_State *L, int i) {
  luaL_checktype(L, i, LUA_TLIGHTUSERDATA);
  return lua_touserdata(L, i);
}

static void push_value(lua_State *L, void *type, void *p) {
  switch (il2cpp_type_get_type(type)) {
    case T_VOID: lua_pushnil(L); return;
    case T_BOOLEAN: lua_pushboolean(L, *(uint8_t *)p); return;
    case T_I1: lua_pushinteger(L, *(int8_t *)p); return;
    case T_U1: lua_pushinteger(L, *(uint8_t *)p); return;
    case T_I2: lua_pushinteger(L, *(int16_t *)p); return;
    case T_CHAR: case T_U2: lua_pushinteger(L, *(uint16_t *)p); return;
    case T_I4: lua_pushinteger(L, *(int32_t *)p); return;
    case T_U4: lua_pushinteger(L, *(uint32_t *)p); return;
    case T_I8: case T_U8: case T_I: case T_U: case T_PTR: case T_FNPTR: lua_pushinteger(L, *(int64_t *)p); return;
    case T_R4: lua_pushnumber(L, *(float *)p); return;
    case T_R8: lua_pushnumber(L, *(double *)p); return;
  }
  void *klass = value_class(type);
  if (!klass) {
    push_object(L, *(void **)p);
  } else if (il2cpp_class_is_enum(klass)) {
    push_value(L, il2cpp_class_enum_basetype(klass), p);
  } else {
    lua_newtable(L);
    FOR_INSTANCE_FIELDS(klass, field) {
      push_value(L, il2cpp_field_get_type(field), (char *)p + il2cpp_field_get_offset(field) - HEADER);
      lua_setfield(L, -2, il2cpp_field_get_name(field));
    }
  }
}

static lua_Integer to_int(lua_State *L, int i) {
  if (lua_isboolean(L, i)) return lua_toboolean(L, i);
  if (lua_islightuserdata(L, i)) return (lua_Integer)(intptr_t)lua_touserdata(L, i);
  return luaL_checkinteger(L, i);
}

static void to_value(lua_State *L, int i, void *type, void *p);

static bool plain_table(lua_State *L, int i) {
  if (!lua_istable(L, i)) return false;
  if (!lua_getmetatable(L, i)) return true;
  lua_pop(L, 1);
  return false;
}

// a plain lua list passed where C# wants an array becomes a new array
static void *to_array(lua_State *L, int i, void *type) {
  void *element = il2cpp_class_get_element_class(il2cpp_class_from_type(type));
  void *element_type = il2cpp_class_get_type(element);
  size_t size = type_size(element_type), n = lua_rawlen(L, i);
  void *array = il2cpp_array_new(element, n), *value = SCRATCH(size);
  for (size_t j = 0; j < n; j++) {
    memset(value, 0, size);
    lua_rawgeti(L, i, (lua_Integer)j + 1);
    to_value(L, -1, element_type, value);
    lua_pop(L, 1);
    store(array, (char *)array + ARRAY_DATA + j * il2cpp_array_element_size(il2cpp_object_get_class(array)), element_type, value);
  }
  return array;
}

// struct fields come by name ({x = 1}) or in declaration order ({1, 2}), missing ones stay 0
static void to_struct(lua_State *L, int i, void *klass, void *p) {
  i = lua_absindex(L, i);
  Object *boxed = luaL_testudata(L, i, OBJECT_MT);
  if (boxed) {
    memcpy(p, il2cpp_object_unbox(boxed->obj), il2cpp_class_value_size(klass, NULL));
    return;
  }
  if (!lua_istable(L, i))
    luaL_error(L, "expected a table for %s, got %s", il2cpp_class_get_name(klass), luaL_typename(L, i));
  int position = 0;
  FOR_INSTANCE_FIELDS(klass, field) {
    position++;
    if (lua_getfield(L, i, il2cpp_field_get_name(field)) == LUA_TNIL) {
      lua_pop(L, 1);
      lua_rawgeti(L, i, position);
    }
    if (!lua_isnil(L, -1))
      to_value(L, -1, il2cpp_field_get_type(field), (char *)p + il2cpp_field_get_offset(field) - HEADER);
    lua_pop(L, 1);
  }
}

static void to_value(lua_State *L, int i, void *type, void *p) {
  switch (il2cpp_type_get_type(type)) {
    case T_BOOLEAN: *(uint8_t *)p = lua_toboolean(L, i); return;
    case T_I1: case T_U1: *(int8_t *)p = (int8_t)to_int(L, i); return;
    case T_CHAR: case T_I2: case T_U2: *(int16_t *)p = (int16_t)to_int(L, i); return;
    case T_I4: case T_U4: *(int32_t *)p = (int32_t)to_int(L, i); return;
    case T_I8: case T_U8: case T_I: case T_U: case T_PTR: case T_FNPTR: *(int64_t *)p = to_int(L, i); return;
    case T_R4: *(float *)p = (float)luaL_checknumber(L, i); return;
    case T_R8: *(double *)p = luaL_checknumber(L, i); return;
  }
  void *klass = value_class(type);
  if (il2cpp_type_get_type(type) == T_SZARRAY && plain_table(L, i)) *(void **)p = to_array(L, i, type);
  else if (!klass) *(void **)p = to_ptr(L, i);
  else if (il2cpp_class_is_enum(klass)) to_value(L, i, il2cpp_class_enum_basetype(klass), p);
  else to_struct(L, i, klass, p);
}

static void set_string(lua_State *L, const char *key, const char *value) {
  lua_pushstring(L, value);
  lua_setfield(L, -2, key);
}

static void set_bool(lua_State *L, const char *key, bool value) {
  lua_pushboolean(L, value);
  lua_setfield(L, -2, key);
}

static void set_pointer(lua_State *L, const char *key, void *value) {
  if (!value) return;
  lua_pushlightuserdata(L, value);
  lua_setfield(L, -2, key);
}

static void push_full_name(lua_State *L, void *klass) {
  void *outer = il2cpp_class_get_declaring_type(klass);
  const char *ns = il2cpp_class_get_namespace(klass);
  if (outer) {
    push_full_name(L, outer);
    lua_pushfstring(L, "%s.%s", lua_tostring(L, -1), il2cpp_class_get_name(klass));
    lua_remove(L, -2);
  } else if (ns && *ns) {
    lua_pushfstring(L, "%s.%s", ns, il2cpp_class_get_name(klass));
  } else {
    lua_pushstring(L, il2cpp_class_get_name(klass));
  }
}

// classes() -> { ["Namespace.Outer.Inner"] = class }
static int l_classes(lua_State *L) {
  lua_newtable(L);
  size_t count;
  void **assemblies = il2cpp_domain_get_assemblies(domain, &count);
  for (size_t i = 0; i < count; i++) {
    void *image = il2cpp_assembly_get_image(assemblies[i]);
    for (size_t j = 0, n = il2cpp_image_get_class_count(image); j < n; j++) {
      void *klass = il2cpp_image_get_class(image, j);
      push_full_name(L, klass);
      lua_pushvalue(L, -1);
      if (lua_rawget(L, -3) == LUA_TNIL) {  // first definition wins
        lua_pop(L, 1);
        lua_pushlightuserdata(L, klass);
        lua_rawset(L, -3);
      } else {
        lua_pop(L, 2);
      }
    }
  }
  return 1;
}

static int l_classinfo(lua_State *L) {
  void *klass = check_light(L, 1);
  lua_newtable(L);
  push_full_name(L, klass);
  lua_setfield(L, -2, "fullname");
  set_pointer(L, "parent", il2cpp_class_get_parent(klass));
  set_bool(L, "valuetype", il2cpp_class_is_valuetype(klass));
  set_bool(L, "enum", il2cpp_class_is_enum(klass));
  return 1;
}

static void push_type_info(lua_State *L, void *type) {
  char *name = il2cpp_type_get_name(type);
  lua_newtable(L);
  set_string(L, "type", name);
  il2cpp_free(name);
  lua_pushinteger(L, il2cpp_type_get_type(type));
  lua_setfield(L, -2, "kind");
  set_bool(L, "byref", il2cpp_type_is_byref(type));
  set_bool(L, "ref", is_ref(type));
  set_pointer(L, "class", il2cpp_class_from_type(type));
}

// methods declared on the class itself (not its parents)
static int l_methods(lua_State *L) {
  void *klass = check_light(L, 1);
  lua_newtable(L);
  void *iter = NULL, *method;
  for (int n = 1; (method = il2cpp_class_get_methods(klass, &iter)); n++) {
    uint32_t flags = il2cpp_method_get_flags(method, NULL);
    uint32_t count = il2cpp_method_get_param_count(method);
    lua_newtable(L);
    set_pointer(L, "ptr", method);
    set_string(L, "name", il2cpp_method_get_name(method));
    set_bool(L, "static", flags & ATTR_STATIC);
    lua_createtable(L, count, 0);
    for (uint32_t i = 0; i < count; i++) {
      push_type_info(L, il2cpp_method_get_param(method, i));
      set_string(L, "name", il2cpp_method_get_param_name(method, i));
      lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "params");
    push_type_info(L, il2cpp_method_get_return_type(method));
    lua_setfield(L, -2, "ret");
    lua_rawseti(L, -2, n);
  }
  return 1;
}

// fields declared on the class itself (not its parents)
static int l_fields(lua_State *L) {
  void *klass = check_light(L, 1);
  lua_newtable(L);
  void *iter = NULL, *field;
  for (int n = 1; (field = il2cpp_class_get_fields(klass, &iter)); n++) {
    push_type_info(L, il2cpp_field_get_type(field));
    set_pointer(L, "ptr", field);
    set_string(L, "name", il2cpp_field_get_name(field));
    lua_pushinteger(L, (lua_Integer)il2cpp_field_get_offset(field));
    lua_setfield(L, -2, "offset");
    set_bool(L, "static", il2cpp_field_get_flags(field) & ATTR_STATIC);
    lua_rawseti(L, -2, n);
  }
  return 1;
}

// invoke(method, self, ...) -> result, then the final values of ref/out parameters
static int l_invoke(lua_State *L) {
  void *method = check_light(L, 1);
  void *self = NULL;
  uint32_t flags = il2cpp_method_get_flags(method, NULL);
  if (!(flags & ATTR_STATIC)) self = check_object(L, 2);
  if (flags & METHOD_VIRTUAL) {
    void *actual = il2cpp_object_get_virtual_method(self, method);
    if (actual) method = actual;
  }
  uint32_t count = il2cpp_method_get_param_count(method);
  void **params = alloca((count + 1) * sizeof(void *));
  void **values = alloca((count + 1) * sizeof(void *));
  for (uint32_t i = 0; i < count; i++) {
    void *type = il2cpp_method_get_param(method, i);
    values[i] = SCRATCH(type_size(type));
    to_value(L, 3 + (int)i, type, values[i]);
    // runtime_invoke takes references as is and everything else (or any ref/out) by address
    params[i] = il2cpp_type_is_byref(type) || !is_ref(type) ? values[i] : *(void **)values[i];
  }
  void *exception = NULL;
  void *result = il2cpp_runtime_invoke(method, self, params, &exception);
  if (exception) {
    char message[1024];
    il2cpp_format_exception(exception, message, sizeof message);
    return luaL_error(L, "%s", message);
  }

  void *ret = il2cpp_method_get_return_type(method);
  if (is_ref(ret)) push_object(L, result);
  else if (result) push_value(L, ret, il2cpp_object_unbox(result));  // value types come back boxed
  else lua_pushnil(L);
  int results = 1;
  for (uint32_t i = 0; i < count; i++) {
    void *type = il2cpp_method_get_param(method, i);
    if (il2cpp_type_is_byref(type)) push_value(L, type, values[i]), results++;
  }
  return results;
}

static bool static_field(void *field) {
  if (!(il2cpp_field_get_flags(field) & ATTR_STATIC)) return false;
  il2cpp_runtime_class_init(il2cpp_field_get_parent(field));
  return true;
}

// getfield(field, self), self is ignored for static fields
static int l_getfield(lua_State *L) {
  void *field = check_light(L, 1);
  void *type = il2cpp_field_get_type(field);
  if (static_field(field)) {
    void *value = SCRATCH(type_size(type));
    il2cpp_field_static_get_value(field, value);
    push_value(L, type, value);
  } else {
    push_value(L, type, (char *)check_object(L, 2) + il2cpp_field_get_offset(field));
  }
  return 1;
}

// setfield(field, self, value)
static int l_setfield(lua_State *L) {
  void *field = check_light(L, 1);
  void *type = il2cpp_field_get_type(field);
  void *value = SCRATCH(type_size(type));
  to_value(L, 3, type, value);
  if (static_field(field)) {
    il2cpp_field_static_set_value(field, is_ref(type) ? *(void **)value : value);
  } else {
    void *self = check_object(L, 2);
    store(self, (char *)self + il2cpp_field_get_offset(field), type, value);
  }
  return 0;
}

static int l_new(lua_State *L) {
  push_object(L, il2cpp_object_new(check_light(L, 1)));
  return 1;
}

static int l_classof(lua_State *L) {
  void *obj = to_ptr(L, 1);
  if (!obj) return 0;
  lua_pushlightuserdata(L, il2cpp_object_get_class(obj));
  return 1;
}

static int l_typeof(lua_State *L) {
  push_object(L, il2cpp_type_get_object(il2cpp_class_get_type(check_light(L, 1))));
  return 1;
}

static int l_assignable(lua_State *L) {
  lua_pushboolean(L, il2cpp_class_is_assignable_from(check_light(L, 1), check_light(L, 2)));
  return 1;
}

// a System.String object, where passing a lua string would only give a copy
static int l_string(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  new_userdata(L, il2cpp_string_new_len(s, (uint32_t)n));
  return 1;
}

// bytes(System.Byte class, s) -> byte[] of the lua string, unbytes(byte[]) -> the lua string
static int l_bytes(lua_State *L) {
  size_t n;
  void *byte = check_light(L, 1);
  const char *s = luaL_checklstring(L, 2, &n);
  void *array = il2cpp_array_new(byte, n);
  memcpy((char *)array + ARRAY_DATA, s, n);
  push_object(L, array);
  return 1;
}

static int l_unbytes(lua_State *L) {
  char *array = check_object(L, 1);
  lua_pushlstring(L, array + ARRAY_DATA, *(uintptr_t *)(array + ARRAY_LENGTH));
  return 1;
}

static void *array_slot(lua_State *L, void *array, lua_Integer i, void **type) {
  uintptr_t length = *(uintptr_t *)((char *)array + ARRAY_LENGTH);
  if (i < 0 || (uintptr_t)i >= length) luaL_error(L, "index %d out of range (length %d)", (int)i, (int)length);
  void *klass = il2cpp_object_get_class(array);
  *type = il2cpp_class_get_type(il2cpp_class_get_element_class(klass));
  return (char *)array + ARRAY_DATA + i * il2cpp_array_element_size(klass);
}

static int l_alen(lua_State *L) {
  lua_pushinteger(L, (lua_Integer) * (uintptr_t *)((char *)check_object(L, 1) + ARRAY_LENGTH));
  return 1;
}

// aget(array, i), 0-based like C#
static int l_aget(lua_State *L) {
  void *type;
  void *slot = array_slot(L, check_object(L, 1), luaL_checkinteger(L, 2), &type);
  push_value(L, type, slot);
  return 1;
}

static int l_aset(lua_State *L) {
  void *array = check_object(L, 1), *type;
  void *slot = array_slot(L, array, luaL_checkinteger(L, 2), &type);
  void *value = SCRATCH(type_size(type));
  to_value(L, 3, type, value);
  store(array, slot, type, value);
  return 0;
}

static int object_gc(lua_State *L) {
  Object *o = luaL_checkudata(L, 1, OBJECT_MT);
  if (o->handle) il2cpp_gchandle_free(o->handle);
  o->handle = 0;
  return 0;
}

static int object_eq(lua_State *L) {
  lua_pushboolean(L, to_ptr(L, 1) == to_ptr(L, 2));
  return 1;
}

static int object_tostring(lua_State *L) {
  void *obj = check_object(L, 1);
  push_full_name(L, il2cpp_object_get_class(obj));
  lua_pushfstring(L, "%s: %p", lua_tostring(L, -1), obj);
  return 1;
}

static const luaL_Reg object_methods[] = {
    {"__gc", object_gc}, {"__eq", object_eq}, {"__tostring", object_tostring}, {NULL, NULL},
};

// how arm64 passes a value: in x registers (int, small struct), v registers (float, hfa) or by address (big)
enum { K_VOID, K_INT, K_FLOAT, K_HFA, K_SMALL, K_BIG };
typedef struct {
  int kind, count, element, size;
} Abi;

// homogeneous float aggregate: a struct made only of floats, or only of doubles
static bool hfa(void *klass, int *element, int *count) {
  FOR_INSTANCE_FIELDS(klass, field) {
    void *type = il2cpp_field_get_type(field);
    int kind = il2cpp_type_get_type(type);
    void *inner = value_class(type);
    if (kind == T_R4 || kind == T_R8) {
      int size = kind == T_R4 ? 4 : 8;
      if (*element && *element != size) return false;
      *element = size;
      ++*count;
    } else if (!inner || il2cpp_class_is_enum(inner) || !hfa(inner, element, count)) {
      return false;
    }
  }
  return true;
}

static Abi classify(void *type) {
  Abi abi = {K_INT, 1, 8, 8};
  int kind = il2cpp_type_get_type(type);
  void *klass = value_class(type);
  if (il2cpp_type_is_byref(type)) return abi;
  if (kind == T_VOID) abi.kind = K_VOID;
  else if (kind == T_R4) abi.kind = K_FLOAT, abi.element = 4;
  else if (kind == T_R8) abi.kind = K_FLOAT;
  else if (klass && !il2cpp_class_is_enum(klass)) {
    int element = 0, count = 0;
    abi.size = il2cpp_class_value_size(klass, NULL);
    if (hfa(klass, &element, &count) && count >= 1 && count <= 4) abi = (Abi){K_HFA, count, element, abi.size};
    else abi.kind = abi.size <= 16 ? K_SMALL : K_BIG;
  }
  return abi;
}

// targets stay hooked for the whole process, a reload only drops the lua hooks
// so a call still running can never jump into freed code
typedef struct {
  void *code, *method;  // method is NULL for the frame tick
  bool is_static, struct_self;
  uint32_t count;
  void *self_type, *ret, **types;
  Abi ret_abi, *abis;
  volatile int befores, afters, skips;  // active lua hooks, read without the lock so calls nobody hooks stay cheap
} Target;

extern char phigrospp_thunks[];
__attribute__((visibility("hidden"))) void *phigrospp_originals[THUNKS];
static Target targets[THUNKS];
static int target_count;

typedef struct {
  int target;
  bool active;
  int before, after, skip;  // registry refs or LUA_NOREF
  int errors;
} Hook;

#define MAX_HOOKS 1024
static Hook hooks[MAX_HOOKS];
static int hook_count;

static void tick(void);

static int target_for(void *code, void *method) {
  for (int i = 0; i < target_count; i++)
    if (targets[i].code == code) return i;
  if (target_count >= THUNKS) return -1;
  int index = target_count;
  Target *t = &targets[index];
  *t = (Target){.code = code, .method = method};
  if (method) {
    void *klass = il2cpp_method_get_class(method);
    t->is_static = il2cpp_method_get_flags(method, NULL) & ATTR_STATIC;
    t->struct_self = !t->is_static && il2cpp_class_is_valuetype(klass);
    t->self_type = il2cpp_class_get_type(klass);
    t->count = il2cpp_method_get_param_count(method);
    t->types = malloc((t->count + 1) * sizeof *t->types);
    t->abis = malloc((t->count + 1) * sizeof *t->abis);
    for (uint32_t i = 0; i < t->count; i++) t->abis[i] = classify(t->types[i] = il2cpp_method_get_param(method, i));
    t->ret_abi = classify(t->ret = il2cpp_method_get_return_type(method));
  }
  if (DobbyHook(code, phigrospp_thunks + 8 * index, &phigrospp_originals[index]) != 0) return -1;
  target_count++;
  return index;
}

static void count_hook(Hook *hook, int delta) {
  targets[hook->target].befores += hook->before != LUA_NOREF ? delta : 0;
  targets[hook->target].afters += hook->after != LUA_NOREF ? delta : 0;
  targets[hook->target].skips += hook->skip != LUA_NOREF ? delta : 0;
}

#define V(v, i) ((uint8_t *)(v) + 16 * (i))

// copies an hfa out of (or back into) consecutive v registers, one element per register
static void gather(void *to, uint8_t *v, Abi abi) {
  for (int j = 0; j < abi.count; j++) memcpy((char *)to + j * abi.element, V(v, j), abi.element);
}
static void scatter(uint8_t *v, void *from, Abi abi) {
  for (int j = 0; j < abi.count; j++) memcpy(V(v, j), (char *)from + j * abi.element, abi.element);
}

// ni/nv: next free x and v register, an argument that doesn't fit is on the stack and shows as nil
static void push_register_arg(lua_State *L, void *type, Abi abi, uint64_t *x, uint8_t *v, int *ni, int *nv) {
  int words = abi.kind == K_SMALL ? (abi.size + 7) / 8 : 1;
  uint8_t tmp[64];
  if (abi.kind == K_FLOAT || abi.kind == K_HFA) {
    if (*nv + abi.count > 8) {
      *nv = 8;
      lua_pushnil(L);
      return;
    }
    gather(tmp, V(v, *nv), abi);
    *nv += abi.count;
    push_value(L, type, tmp);
  } else if (*ni + words > 8) {
    *ni = 8;
    lua_pushnil(L);
  } else {
    bool by_address = abi.kind == K_BIG || il2cpp_type_is_byref(type);
    push_value(L, type, by_address ? (void *)x[*ni] : &x[*ni]);
    *ni += words;
  }
}

static int push_args(lua_State *L, Target *t, uint64_t *x, uint8_t *v) {
  int ni = 0, nv = 0, n = 0;
  if (!t->is_static) {
    if (t->struct_self) push_value(L, t->self_type, (void *)x[0]);
    else push_object(L, (void *)x[0]);
    ni = n = 1;
  }
  for (uint32_t i = 0; i < t->count; i++, n++) push_register_arg(L, t->types[i], t->abis[i], x, v, &ni, &nv);
  return n;
}

// big structs are returned through the address the caller passed in x8
static void *return_slot(Abi abi, uint64_t *x, uint8_t *v, uint64_t x8, uint8_t *tmp) {
  switch (abi.kind) {
    case K_FLOAT: case K_HFA: gather(tmp, v, abi); return tmp;
    case K_BIG: return (void *)x8;
    default: return x;
  }
}

typedef struct {
  Target *target;
  uint64_t *x;
  uint8_t *v;
  uint64_t x8;
} ReturnSlot;

// (value, slot): replaces the hooked method's result, run protected since a wrong type raises
static int l_write_return(lua_State *L) {
  ReturnSlot *r = lua_touserdata(L, 2);
  Abi abi = r->target->ret_abi;
  uint8_t tmp[64] = {0};
  if (abi.kind == K_VOID) return 0;
  void *slot = return_slot(abi, r->x, r->v, r->x8, tmp);
  if (abi.kind != K_BIG) memset(slot, 0, abi.kind == K_SMALL && abi.size > 8 ? 16 : 8);
  to_value(L, 1, r->target->ret, slot);
  if (abi.kind == K_FLOAT || abi.kind == K_HFA) scatter(r->v, tmp, abi);
  return 0;
}

static int traceback(lua_State *L) {
  luaL_traceback(L, L, lua_tostring(L, 1), 1);
  return 1;
}

static void hook_error(Hook *hook) {
  void *method = targets[hook->target].method;
  LOGE("hook %s.%s: %s", il2cpp_class_get_name(il2cpp_method_get_class(method)), il2cpp_method_get_name(method),
       lua_tostring(L, -1));
  if (++hook->errors >= MAX_ERRORS) {
    LOGE("too many errors, hook disabled");
    hook->active = false;
    count_hook(hook, -1);
  }
}

// called by thunks.S before the original, slot is per-call storage kept until phigrospp_leave:
// [args table ref, x8, generation]. returns true when a skip hook asked to skip the original
bool phigrospp_enter(size_t id, uint64_t *x, uint8_t *v, uint64_t *slot) {
  Target *t = &targets[id];
  bool skip = false;
  slot[0] = 0;
  if (!t->method) {
    tick();
    return false;
  }
  if (!t->befores && !t->afters && !t->skips) return false;
  pthread_mutex_lock(&lock);
  if (L) {
    ensure_attached();
    int top = lua_gettop(L);
    lua_pushcfunction(L, traceback);
    int handler = top + 1;
    if (t->afters) {
      int n = push_args(L, t, x, v);
      lua_createtable(L, n, 0);
      lua_insert(L, -n - 1);
      for (int i = n; i >= 1; i--) lua_rawseti(L, -i - 1, i);
      slot[0] = (uint64_t)luaL_ref(L, LUA_REGISTRYINDEX);
      slot[1] = x[8];
      slot[2] = generation;
    }
    for (int i = 0; t->befores && i < hook_count; i++) {
      Hook *hook = &hooks[i];
      if (!hook->active || hook->target != (int)id || hook->before == LUA_NOREF) continue;
      lua_rawgeti(L, LUA_REGISTRYINDEX, hook->before);
      if (lua_pcall(L, push_args(L, t, x, v), 0, handler) != LUA_OK) hook_error(hook);
      lua_settop(L, handler);
    }
    // a skip hook returning true keeps the original from running, it returns zero. a failing one skips too, since
    // skip hooks exist to keep something from happening
    for (int i = 0; t->skips && i < hook_count && !skip; i++) {
      Hook *hook = &hooks[i];
      if (!hook->active || hook->target != (int)id || hook->skip == LUA_NOREF) continue;
      lua_rawgeti(L, LUA_REGISTRYINDEX, hook->skip);
      if (lua_pcall(L, push_args(L, t, x, v), 1, handler) != LUA_OK) {
        hook_error(hook);
        skip = true;
      } else {
        skip = lua_toboolean(L, -1);
      }
      lua_settop(L, handler);
    }
    if (skip) {
      memset(x, 0, 2 * sizeof *x);
      memset(v, 0, 4 * 16);
      if (slot[0]) luaL_unref(L, LUA_REGISTRYINDEX, (int)slot[0]);
      slot[0] = 0;
    }
    lua_settop(L, top);
  }
  pthread_mutex_unlock(&lock);
  return skip;
}

// called by thunks.S after the original, x and v now hold its return registers
void phigrospp_leave(size_t id, uint64_t *x, uint8_t *v, uint64_t *slot) {
  if (!slot[0]) return;
  pthread_mutex_lock(&lock);
  if (L && slot[2] == generation) {
    Target *t = &targets[id];
    int ref = (int)slot[0];
    int top = lua_gettop(L);
    uint8_t tmp[64];
    ensure_attached();
    lua_pushcfunction(L, traceback);
    int handler = top + 1;
    for (int i = 0; i < hook_count; i++) {
      Hook *hook = &hooks[i];
      if (!hook->active || hook->target != (int)id || hook->after == LUA_NOREF) continue;
      lua_rawgeti(L, LUA_REGISTRYINDEX, hook->after);
      lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
      int n = (int)lua_rawlen(L, -1);
      for (int j = 1; j <= n; j++) lua_rawgeti(L, handler + 2, j);
      lua_remove(L, handler + 2);
      // an earlier hook may have replaced the result, so it's read again for each one
      if (t->ret_abi.kind == K_VOID) lua_pushnil(L);
      else push_value(L, t->ret, return_slot(t->ret_abi, x, v, slot[1], tmp));
      if (lua_pcall(L, n + 1, 1, handler) != LUA_OK) {
        hook_error(hook);
      } else if (!lua_isnil(L, -1)) {
        ReturnSlot target = {t, x, v, slot[1]};
        lua_pushcfunction(L, l_write_return);
        lua_insert(L, -2);
        lua_pushlightuserdata(L, &target);
        if (lua_pcall(L, 2, 0, handler) != LUA_OK) hook_error(hook);
      }
      lua_settop(L, handler);
    }
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
    lua_settop(L, top);
  }
  pthread_mutex_unlock(&lock);
}

static int optional_function(lua_State *L, int i) {
  if (lua_isnoneornil(L, i)) return LUA_NOREF;
  luaL_checktype(L, i, LUA_TFUNCTION);
  lua_pushvalue(L, i);
  return luaL_ref(L, LUA_REGISTRYINDEX);
}

// hook(method, before, after, skip) -> id
static int l_hook(lua_State *L) {
  void *method = check_light(L, 1);
  void *code = *(void **)method;  // MethodInfo.methodPointer
  if (!code) return luaL_error(L, "%s has no code (abstract or generic?)", il2cpp_method_get_name(method));
  if (hook_count >= MAX_HOOKS) return luaL_error(L, "too many hooks");
  int target = target_for(code, method);
  if (target < 0) return luaL_error(L, "couldn't hook %s", il2cpp_method_get_name(method));
  if (!targets[target].method) return luaL_error(L, "%s is used by Phigros++ itself", il2cpp_method_get_name(method));
  hooks[hook_count] = (Hook){target, true, optional_function(L, 2), optional_function(L, 3), optional_function(L, 4), 0};
  count_hook(&hooks[hook_count], 1);
  lua_pushinteger(L, hook_count++);
  return 1;
}

static int l_unhook(lua_State *L) {
  lua_Integer id = luaL_checkinteger(L, 1);
  if (id < 0 || id >= hook_count || !hooks[id].active) return 0;
  hooks[id].active = false;
  count_hook(&hooks[id], -1);
  return 0;
}

static int l_print(lua_State *L) {
  int n = lua_gettop(L);  // before luaL_buffinit, which pushes a placeholder
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int i = 1; i <= n; i++) {
    if (i > 1) luaL_addchar(&b, '\t');
    luaL_tolstring(L, i, NULL);
    luaL_addvalue(&b);
  }
  luaL_pushresult(&b);
  LOGI("%s", lua_tostring(L, -1));
  return 0;
}

// the next frame builds a new lua state, from the bundle phigros++/bundle may now hold
static int l_reload(lua_State *L) {
  (void)L;
  load_pending = 1;
  return 0;
}

static int l_now(lua_State *L) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  lua_pushnumber(L, ts.tv_sec + ts.tv_nsec / 1e9);
  return 1;
}

static const luaL_Reg raw_functions[] = {
    {"classes", l_classes}, {"classinfo", l_classinfo}, {"methods", l_methods}, {"fields", l_fields},
    {"invoke", l_invoke}, {"getfield", l_getfield}, {"setfield", l_setfield}, {"new", l_new},
    {"classof", l_classof}, {"typeof", l_typeof}, {"assignable", l_assignable}, {"string", l_string},
    {"alen", l_alen}, {"aget", l_aget}, {"aset", l_aset}, {"bytes", l_bytes}, {"unbytes", l_unbytes},
    {"hook", l_hook}, {"unhook", l_unhook}, {NULL, NULL},
};

// runs the function under the top `nargs` values, logging any error
static bool run(int nargs, const char *what) {
  int base = lua_gettop(L) - nargs;
  lua_pushcfunction(L, traceback);
  lua_insert(L, base);
  bool ok = lua_pcall(L, nargs, 0, base) == LUA_OK;
  if (!ok) LOGE("%s: %s", what, lua_tostring(L, -1));
  lua_settop(L, base - 1);
  return ok;
}

static void emit(const char *event) {
  if (lua_getglobal(L, "__phigrospp_emit") != LUA_TFUNCTION) {
    lua_pop(L, 1);
    return;
  }
  lua_pushstring(L, event);
  run(1, event);
}

static void unload(void) {
  if (!L) return;
  emit("unload");
  for (int i = 0; i < target_count; i++) targets[i].befores = targets[i].afters = targets[i].skips = 0;
  hook_count = 0;
  generation++;
  lua_close(L);
  L = NULL;
}

static int compare_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// adds the mod a name in mods/ is: a folder, or a .lua file without its extension. names starting with _ or . are
// skipped
static int add_mod(char **names, int count, const char *name, size_t size) {
  const char *dot = memrchr(name, '.', size);
  if (count == 256 || name[0] == '.' || name[0] == '_' || (dot && (name + size - dot != 4 || memcmp(dot, ".lua", 4))))
    return count;
  names[count] = strndup(name, dot ? (size_t)(dot - name) : size);
  return count + 1;
}

// the mods of phigros++/mods/ and of the bundle, in name order
static void load_mods(Bundle bundle) {
  char dir[600], *names[256];
  int count = 0;
  snprintf(dir, sizeof dir, "%s/mods", root);
  DIR *d = opendir(dir);
  for (struct dirent *entry; d && (entry = readdir(d));) count = add_mod(names, count, entry->d_name, strlen(entry->d_name));
  if (d) closedir(d);
  const char *file, *data;
  size_t file_size, size;
  while (next_file(&bundle, &file, &file_size, &data, &size))
    if (file_size > 5 && !memcmp(file, "mods/", 5)) {
      const char *slash = memchr(file + 5, '/', file_size - 5);
      count = add_mod(names, count, file + 5, (slash ? slash : file + file_size) - (file + 5));
    }
  qsort(names, count, sizeof *names, compare_names);
  // through require, so a mod another one already required runs only once
  for (int i = 0; i < count; i++) {
    if (i && !strcmp(names[i], names[i - 1])) continue;
    lua_getglobal(L, "require");
    lua_pushstring(L, names[i]);
    if (run(1, names[i])) LOGI("loaded %s", names[i]);
  }
  for (int i = 0; i < count; i++) free(names[i]);
}

static void load(void) {
  char path[600];
  unload();
  L = luaL_newstate();
  luaL_openlibs(L);
  lua_register(L, "print", l_print);
  lua_register(L, "now", l_now);
  lua_createtable(L, 0, 10);
  set_string(L, "root", root);
  lua_pushcfunction(L, l_reload);
  lua_setfield(L, -2, "reload");
  open_sync(L);
  Bundle bundle = open_bundle(L, root);
  lua_setglobal(L, "phigrospp");

  luaL_newmetatable(L, OBJECT_MT);  // the prelude adds __index, __newindex and __len
  luaL_setfuncs(L, object_methods, 0);
  lua_pop(L, 1);
  lua_newtable(L);
  lua_newtable(L);
  set_string(L, "__mode", "v");
  lua_setmetatable(L, -2);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &CACHE_KEY);

  luaL_newlib(L, raw_functions);
  lua_pushinteger(L, MAX_ERRORS);
  lua_setfield(L, -2, "max_errors");
  luaL_getmetatable(L, OBJECT_MT);
  lua_setfield(L, -2, "object_mt");
  lua_setglobal(L, "__il2cpp");

  lua_getglobal(L, "package");
  lua_pushfstring(L, "%s/mods/?.lua;%s/mods/?/init.lua", root, root);
  lua_setfield(L, -2, "path");
  lua_pop(L, 1);

  // the bundle's core/<name>.lua in order. the same file in the phigros++ folder replaces it, to work on it without
  // reinstalling
  Bundle files = bundle;
  const char *file, *source;
  size_t file_size, size;
  while (next_file(&files, &file, &file_size, &source, &size)) {
    if (file_size < 10 || memcmp(file, "core/", 5) || memcmp(file + file_size - 4, ".lua", 4)) continue;
    char name[64];
    snprintf(name, sizeof name, "%.*s", (int)file_size - 9, file + 5);
    snprintf(path, sizeof path, "%s/core/%s.lua", root, name);
    int status = luaL_loadfilex(L, path, "t");
    if (status == LUA_ERRFILE) {
      lua_pop(L, 1);
      lua_pushfstring(L, "=%s", name);
      status = luaL_loadbufferx(L, source, size, lua_tostring(L, -1), "t");
      lua_remove(L, -2);
    }
    if (status != LUA_OK) LOGE("%s", lua_tostring(L, -1));
    if (status != LUA_OK || !run(0, name)) {
      lua_close(L);
      L = NULL;
      return;
    }
  }
  load_mods(bundle);
  emit("load");
}

static uint64_t signature(const char *dir, int depth) {
  uint64_t hash = 1469598103934665603ULL;  // fnv-1a over names, mtimes and sizes
  DIR *d = opendir(dir);
  if (!d) return hash;
  for (struct dirent *entry; (entry = readdir(d));) {
    char path[1024];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s", dir, entry->d_name);
    if (entry->d_name[0] == '.' || stat(path, &st) != 0) continue;
    for (const char *c = entry->d_name; *c; c++) hash = (hash ^ (uint8_t)*c) * 1099511628211ULL;
    hash = (hash ^ (uint64_t)st.st_mtime) * 1099511628211ULL;
    hash = (hash ^ (uint64_t)st.st_size) * 1099511628211ULL;
    if (S_ISDIR(st.st_mode) && depth > 0) hash ^= signature(path, depth - 1) * 31;
  }
  closedir(d);
  return hash;
}

static void tick(void) {
  pthread_mutex_lock(&lock);
  ensure_attached();
  if (load_pending) {
    load_pending = 0;
    load();
  }
  if (L) emit("update");
  pthread_mutex_unlock(&lock);
}

// only mods/ and core/, so mods can write their own files (like settings) next to them
static uint64_t watched(void) {
  char path[600];
  snprintf(path, sizeof path, "%s/core", root);
  uint64_t hash = signature(path, 0);
  snprintf(path, sizeof path, "%s/mods", root);
  return hash ^ signature(path, 1) * 31;
}

static void *watch_files(void *unused) {
  (void)unused;
  for (uint64_t last = watched(), now;; last = now) {
    sleep(1);
    now = watched();
    if (now != last) {
      LOGI("files changed, reloading");
      load_pending = 1;
    }
  }
  return NULL;
}

static void *find_method(const char *namespace_, const char *class_name, const char *method_name) {
  size_t count;
  void **assemblies = il2cpp_domain_get_assemblies(domain, &count);
  for (size_t i = 0; i < count; i++) {
    void *klass = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), namespace_, class_name);
    void *method = klass ? il2cpp_class_get_method_from_name(klass, method_name, 0) : NULL;
    if (method) return *(void **)method;
  }
  return NULL;
}

static void start(void) {
  int missing = 0;
#define RESOLVE(ret, name, args)                                     \
  il2cpp_##name = (ret(*) args)dlsym(il2cpp_handle, "il2cpp_" #name); \
  if (!il2cpp_##name) {                                              \
    LOGE("missing il2cpp_%s", #name);                                \
    missing++;                                                       \
  }
  IL2CPP_API(RESOLVE)
#undef RESOLVE
  if (missing) return;
  domain = il2cpp_domain_get();
  ensure_attached();
  string_class = il2cpp_object_get_class(il2cpp_string_new_len("", 0));

  // per-frame methods on the main thread, in every scene: the first one found drives tick()
  static const char *ticks[][3] = {
      {"UnityEngine.UI", "CanvasUpdateRegistry", "PerformUpdate"},
      {"UnityEngine.EventSystems", "EventSystem", "Update"},
  };
  for (size_t i = 0; i < sizeof ticks / sizeof *ticks; i++) {
    void *code = find_method(ticks[i][0], ticks[i][1], ticks[i][2]);
    if (!code) continue;
    if (target_for(code, NULL) < 0) {
      LOGE("couldn't hook %s.%s", ticks[i][1], ticks[i][2]);
      return;
    }
    pthread_t thread;
    pthread_create(&thread, NULL, watch_files, NULL);
    load_pending = 1;
    LOGI("Phigros++ ready, ticking on %s.%s, mods in %s/mods", ticks[i][1], ticks[i][2], root);
    return;
  }
  LOGE("no per-frame method found, mods won't load");
}

// the linker picks the namespace of a library from the caller address, so the hooks below
// call the linker directly with the real caller instead of going through libdl
static void *(*loader_dlopen)(const char *, int, const void *);
static void *(*loader_android_dlopen_ext)(const char *, int, const void *, const void *);
static int (*original_il2cpp_init)(const char *);

static int hooked_il2cpp_init(const char *domain_name) {
  int result = original_il2cpp_init(domain_name);
  start();
  return result;
}

static void loaded(const char *filename, void *handle) {
  size_t n = filename ? strlen(filename) : 0;
  if (!handle || il2cpp_handle || n < 12 || strcmp(filename + n - 12, "libil2cpp.so")) return;
  il2cpp_handle = handle;
  void *init = dlsym(handle, "il2cpp_init");
  if (!init || DobbyHook(init, (void *)hooked_il2cpp_init, (void **)&original_il2cpp_init) != 0)
    LOGE("couldn't hook il2cpp_init");
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

static void find_root(void) {
  char package[256] = "sh.molly.phigrosplusplus";
  FILE *f = fopen("/proc/self/cmdline", "r");
  if (f) {
    package[fread(package, 1, sizeof package - 1, f)] = 0;
    fclose(f);
  }
  char *process = strchr(package, ':');
  if (process) *process = 0;
  snprintf(root, sizeof root, "/sdcard/Android/data/%s/files/phigros++", package);
}

__attribute__((constructor)) static void boot(void) {
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&lock, &attr);
  find_root();
  loader_dlopen = libdl_import("__loader_dlopen");
  loader_android_dlopen_ext = libdl_import("__loader_android_dlopen_ext");
  if (!loader_dlopen || !loader_android_dlopen_ext ||
      DobbyHook(dlsym(RTLD_DEFAULT, "dlopen"), (void *)hooked_dlopen, NULL) != 0 ||
      DobbyHook(dlsym(RTLD_DEFAULT, "android_dlopen_ext"), (void *)hooked_android_dlopen_ext, NULL) != 0)
    LOGE("couldn't hook dlopen, Phigros++ is off");
}
