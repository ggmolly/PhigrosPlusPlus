// what syncing with phigros.tools needs from C: randomness, sha-512, ed25519 keys and signatures, and x25519 for
// pairing a device. all keys and hashes are lua strings of raw bytes
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "lauxlib.h"
#include "tweetnacl.c"  // included rather than linked, to derive key pairs from a seed with its static helpers

void randombytes(u8 *out, u64 n) {
  while (n) {
    long got = syscall(__NR_getrandom, out, n, 0);
    if (got > 0) out += got, n -= got;
  }
}

// crypto_sign_keypair with the secret seed given instead of drawn
static void keypair(u8 pk[32], u8 sk[64], const u8 *seed) {
  u8 d[64];
  gf p[4];
  memcpy(sk, seed, 32);
  crypto_hash(d, sk, 32);
  d[0] &= 248;
  d[31] &= 127;
  d[31] |= 64;
  scalarbase(p, d);
  pack(pk, p);
  memcpy(sk + 32, pk, 32);
}

static const u8 *check_bytes(lua_State *L, int i, size_t size) {
  size_t n;
  const char *s = luaL_checklstring(L, i, &n);
  luaL_argcheck(L, n == size, i, "wrong length");
  return (const u8 *)s;
}

static int l_random(lua_State *L) {
  size_t n = (size_t)luaL_checkinteger(L, 1);
  luaL_Buffer b;
  randombytes((u8 *)luaL_buffinitsize(L, &b, n), n);
  luaL_pushresultsize(&b, n);
  return 1;
}

static int l_sha512(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  u8 out[64];
  crypto_hash(out, (const u8 *)s, n);
  lua_pushlstring(L, (char *)out, 64);
  return 1;
}

// keypair(seed) -> public key
static int l_keypair(lua_State *L) {
  u8 pk[32], sk[64];
  keypair(pk, sk, check_bytes(L, 1, 32));
  lua_pushlstring(L, (char *)pk, 32);
  return 1;
}

// sign(seed, message) -> the 64 byte signature
static int l_sign(lua_State *L) {
  u8 pk[32], sk[64];
  keypair(pk, sk, check_bytes(L, 1, 32));
  size_t n;
  const char *m = luaL_checklstring(L, 2, &n);
  u8 *signed_message = malloc(n + 64);
  u64 length;
  crypto_sign(signed_message, &length, (const u8 *)m, n, sk);
  lua_pushlstring(L, (char *)signed_message, 64);
  free(signed_message);
  return 1;
}

// x25519(secret) -> public key, x25519(secret, public) -> shared secret
static int l_x25519(lua_State *L) {
  u8 out[32];
  if (lua_isnoneornil(L, 2)) crypto_scalarmult_base(out, check_bytes(L, 1, 32));
  else crypto_scalarmult(out, check_bytes(L, 1, 32), check_bytes(L, 2, 32));
  lua_pushlstring(L, (char *)out, 32);
  return 1;
}

static const luaL_Reg crypto_functions[] = {
    {"random", l_random}, {"sha512", l_sha512}, {"keypair", l_keypair}, {"sign", l_sign}, {"x25519", l_x25519},
    {NULL, NULL},
};

// adds crypto to the table on top of the stack
void open_sync(lua_State *L) {
  luaL_newlib(L, crypto_functions);
  lua_setfield(L, -2, "crypto");
}
