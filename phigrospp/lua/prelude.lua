-- the mod api (see the wiki's Mod API page) on top of the raw bridge from phigrospp.c

local raw = __il2cpp
__il2cpp = nil
local OBJECT = raw.object_mt
local ClassMT, NamespaceMT = {}, {}

-- Il2CppTypeEnum values used below
local K = { BOOLEAN = 0x02, CHAR = 0x03, U8 = 0x0b, R4 = 0x0c, R8 = 0x0d, STRING = 0x0e, PTR = 0x0f, VAR = 0x13,
  I = 0x18, U = 0x19, SZARRAY = 0x1d, MVAR = 0x1e }

local function memo(build)
  local cache = {}
  return function(key)
    local value = cache[key]
    if value == nil then
      value = build(key)
      cache[key] = value
    end
    return value
  end
end

local classes = raw.classes()
local UnityObject = classes["UnityEngine.Object"]
local MAX_ERRORS = raw.max_errors
local namespaces = {}
for name in pairs(classes) do
  local prefix = name:match("^(.*)%.")
  while prefix and not namespaces[prefix] do
    namespaces[prefix] = true
    prefix = prefix:match("^(.*)%.")
  end
end

local info = memo(raw.classinfo)
local isUnityObject = memo(function(k) return raw.assignable(UnityObject, k) end)

-- unity objects created by mods, destroyed on reload so mods never clean up after themselves
local created = {}

local function track(obj)
  created[#created + 1] = obj
  return obj
end

-- iterates a class, then its parents
local function lineage(k)
  return function(_, c)
    if c == nil then return k end
    return info(c).parent
  end
end

local function generic(m)
  for _, p in ipairs(m.params) do
    if p.kind == K.VAR or p.kind == K.MVAR then return true end
  end
  return m.ret.kind == K.VAR or m.ret.kind == K.MVAR
end

local function describe(m)
  local parts = {}
  for i, p in ipairs(m.params) do parts[i] = p.type .. " " .. (p.name or "") end
  return ("%s%s(%s)"):format(m.static and "static " or "", m.name, table.concat(parts, ", "))
end

local function describeAll(list)
  local all = {}
  for i, m in ipairs(list) do all[i] = describe(m) end
  return table.concat(all, ", ")
end

-- callable methods of a class, generic ones left out since they can't be invoked
local function callable(k)
  local list = {}
  for _, m in ipairs(raw.methods(k)) do
    if not generic(m) then
      for _, p in ipairs(m.params) do m.takesType = m.takesType or p.type == "System.Type" end
      m.creates = k == UnityObject and m.name == "Instantiate"
      list[#list + 1] = m
    end
  end
  return list
end

-- fields and methods of a class and its parents, the most derived one wins (so overrides appear once)
local members = memo(function(k)
  local r, seen = { fields = {}, methods = {} }, {}
  for c in lineage(k) do
    for _, f in ipairs(raw.fields(c)) do r.fields[f.name] = r.fields[f.name] or f end
    for _, m in ipairs(callable(c)) do
      local key = m.name .. (m.static and " static" or "")
      for _, p in ipairs(m.params) do key = key .. " " .. p.type end
      if not seen[key] then
        seen[key] = true
        r.methods[m.name] = r.methods[m.name] or {}
        table.insert(r.methods[m.name], m)
      end
    end
  end
  return r
end)

-- how well lua value v fits parameter p: nil if it can't, higher is better
local function fit(p, v)
  local t, kind = type(v), p.kind
  if p.byref then return 1 end
  if v == nil then return p.ref and 1 or nil end
  if t == "boolean" then return kind == K.BOOLEAN and 3 or nil end
  if t == "number" then
    local integer = math.type(v) == "integer"
    if kind == K.R4 or kind == K.R8 then return 3 end
    if (kind >= K.CHAR and kind <= K.U8) or kind == K.I or kind == K.U or kind == K.PTR then return integer and 3 or nil end
    return p.class and info(p.class).enum and integer and 2 or nil
  end
  if t == "string" then return kind == K.STRING and 3 or p.type == "System.Object" and 1 or nil end
  if t == "table" then
    if getmetatable(v) == ClassMT then return p.type == "System.Type" and 3 or nil end
    if kind == K.SZARRAY then return getmetatable(v) == nil and 2 or nil end
    local c = p.class and info(p.class)
    return not p.ref and c and c.valuetype and not c.enum and 2 or nil
  end
  if t == "userdata" and getmetatable(v) == OBJECT and p.class then
    local vc = raw.classof(v)
    return vc == p.class and 3 or raw.assignable(p.class, vc) and 2 or nil
  end
  return t == "lightuserdata" and 1 or nil
end

local function pick(list, name, args)
  local best, bestScore
  for _, m in ipairs(list) do
    local score = #m.params == args.n and 0 or nil
    for i, p in ipairs(m.params) do
      local s = score and fit(p, args[i])
      score = s and score + s
    end
    if score and (not best or score > bestScore) then best, bestScore = m, score end
  end
  if best then return best end
  local given = {}
  for i = 1, args.n do given[i] = type(args[i]) end
  error(("%s: no overload takes (%s), there is %s"):format(name, table.concat(given, ", "), describeAll(list)), 3)
end

-- a function calling the best overload of `list` for its arguments, static ones take no self
local function caller(list, name, static)
  local own = {}
  for _, m in ipairs(list) do
    if m.static == static then own[#own + 1] = m end
  end
  local function call(self, ...)
    local args = table.pack(...)
    local m = #own == 1 and #own[1].params == args.n and own[1] or pick(own, name, args)
    if m.takesType then
      for i, p in ipairs(m.params) do
        if p.type == "System.Type" and getmetatable(args[i]) == ClassMT then args[i] = raw.typeof(args[i].__ptr) end
      end
    end
    if m.creates then return track(raw.invoke(m.ptr, self, table.unpack(args, 1, args.n))) end
    return raw.invoke(m.ptr, self, table.unpack(args, 1, args.n))
  end
  if static then return function(...) return call(nil, ...) end end
  return call
end

local function hasStatic(list, static)
  for _, m in ipairs(list or {}) do
    if m.static == static then return true end
  end
  return false
end

local function getter(r, key, static)
  for _, m in ipairs(r.methods["get_" .. key] or {}) do
    if m.static == static and #m.params == 0 then return m end
  end
end

local function setter(r, key, static)
  local list = r.methods["set_" .. key]
  return hasStatic(list, static) and caller(list, "set_" .. key, static) or nil
end

-- per class and key, a function doing obj[key] (or obj[key] = value), false when there's no such member
local function accessors(build)
  local byClass = memo(function(k) return memo(function(key) return build(members(k), key) or false end) end)
  return function(obj, key, verb)
    local k = raw.classof(obj)
    local access = byClass(k)(key)
    if not access then error(("%s has no %s %s"):format(info(k).fullname, verb, tostring(key)), 3) end
    return access
  end
end

local reader = accessors(function(r, key)
  local f, list = r.fields[key], r.methods[key]
  if f then return function(obj) return raw.getfield(f.ptr, obj) end end
  if list then
    local fn = caller(list, key, not hasStatic(list, false))
    return function() return fn end
  end
  local get = getter(r, key, false) or getter(r, key, true)
  return get and function(obj) return raw.invoke(get.ptr, obj) end
end)

local writer = accessors(function(r, key)
  local f = r.fields[key]
  if f then return function(obj, v) raw.setfield(f.ptr, obj, v) end end
  local static = setter(r, key, true)
  return setter(r, key, false) or static and function(_, v) static(v) end
end)

OBJECT.__index = function(obj, key)
  if math.type(key) == "integer" then return raw.aget(obj, key) end
  return reader(obj, key, "member")(obj)
end

OBJECT.__newindex = function(obj, key, value)
  if math.type(key) == "integer" then return raw.aset(obj, key, value) end
  writer(obj, key, "writable member")(obj, value)
end

OBJECT.__len = raw.alen

local proxy = memo(function(k) return setmetatable({ __ptr = k, __name = info(k).fullname }, ClassMT) end)

ClassMT.__index = function(cls, key)
  local r = members(cls.__ptr)
  local f, list = r.fields[key], r.methods[key]
  if f and f.static then return raw.getfield(f.ptr) end
  local get = getter(r, key, true)
  if get then return raw.invoke(get.ptr) end
  local value
  -- Class.Method(...) calls the static overloads, or the instance ones with self first if there are none
  if list then value = caller(list, key, hasStatic(list, true))
  elseif classes[cls.__name .. "." .. key] then value = proxy(classes[cls.__name .. "." .. key])
  else error(("%s has no static member %s"):format(cls.__name, tostring(key)), 2) end
  rawset(cls, key, value)
  return value
end

ClassMT.__newindex = function(cls, key, value)
  local r = members(cls.__ptr)
  local f, set = r.fields[key], setter(r, key, true)
  if f and f.static then return raw.setfield(f.ptr, nil, value) end
  if set then return set(value) end
  error(("%s has no writable static member %s"):format(cls.__name, tostring(key)), 2)
end

local constructor = memo(function(k)
  local own = {}
  for _, m in ipairs(callable(k)) do
    if m.name == ".ctor" and not m.static then own[#own + 1] = m end
  end
  return #own > 0 and caller(own, info(k).fullname .. " constructor", false)
end)

local instanceFields = memo(function(k)
  local names = {}
  for _, f in ipairs(raw.fields(k)) do
    if not f.static then names[#names + 1] = f.name end
  end
  return names
end)

-- structs are built as tables of their fields, in declaration order
ClassMT.__call = function(cls, ...)
  local k = cls.__ptr
  if info(k).valuetype then
    local t = {}
    for i, name in ipairs(instanceFields(k)) do t[name] = select(i, ...) or 0 end
    return t
  end
  local obj, construct = raw.new(k), constructor(k)
  if construct then construct(obj, ...) end
  if isUnityObject(k) then track(obj) end
  return obj
end

ClassMT.__tostring = function(cls) return "class " .. cls.__name end

local function namespace(path) return setmetatable({ __path = path }, NamespaceMT) end

NamespaceMT.__index = function(ns, key)
  local full = ns.__path == "" and key or ns.__path .. "." .. key
  local value = classes[full] and proxy(classes[full]) or namespaces[full] and namespace(full)
  if not value then error(("CS.%s doesn't exist"):format(full), 2) end
  rawset(ns, key, value)
  return value
end

NamespaceMT.__tostring = function(ns) return "namespace " .. ns.__path end

CS = namespace("")

local function classOf(target)
  if getmetatable(target) == ClassMT then return target.__ptr end
  if type(target) == "string" and classes[target] then return classes[target] end
  error("expected a class, got " .. tostring(target), 3)
end

local opImplicit

il2cpp = {
  string = raw.string,
  -- a byte[] of a lua string, and back
  bytes = function(s) return raw.bytes(classes["System.Byte"], s) end,
  unbytes = raw.unbytes,
  class = function(name) return classes[name] and proxy(classes[name]) end,
  classof = function(obj) return obj ~= nil and proxy(raw.classof(obj)) or nil end,
  is = function(obj, cls) return obj ~= nil and raw.assignable(classOf(cls), raw.classof(obj)) end,
  typeof = function(cls) return raw.typeof(classOf(cls)) end,
  alive = function(obj)
    if obj == nil then return false end
    if not isUnityObject(raw.classof(obj)) then return true end
    opImplicit = opImplicit or CS.UnityEngine.Object.op_Implicit
    return opImplicit(obj)
  end,
  find = function(pattern)
    local found = {}
    for name in pairs(classes) do
      if name:find(pattern) then found[#found + 1] = name end
    end
    table.sort(found)
    return found
  end,
  describe = function(cls)
    local lines = {}
    for c in lineage(classOf(cls)) do
      local i = info(c)
      lines[#lines + 1] = i.fullname
      for _, f in ipairs(raw.fields(c)) do
        lines[#lines + 1] = ("  %s%s %s @0x%x"):format(f.static and "static " or "", f.type, f.name, f.offset)
      end
      for _, m in ipairs(raw.methods(c)) do lines[#lines + 1] = ("  %s -> %s"):format(describe(m), m.ret.type) end
    end
    return table.concat(lines, "\n")
  end,
}

function hook(cls, name, params, callbacks)
  if callbacks == nil then params, callbacks = nil, params end
  local k = classOf(cls)
  local list = members(k).methods[name] or error(("%s has no method %s"):format(info(k).fullname, name), 2)
  local matches = {}
  for _, m in ipairs(list) do
    local ok = params == nil or #m.params == (type(params) == "table" and #params or params)
    for i, p in ipairs(type(params) == "table" and m.params or {}) do
      ok = ok and (params[i] == "*" or params[i] == p.type)
    end
    if ok then matches[#matches + 1] = m end
  end
  if #matches ~= 1 then
    error(("hook %s.%s: %d overloads match, pass params to pick one of %s"):format(info(k).fullname, name, #matches,
      describeAll(list)), 2)
  end
  return raw.hook(matches[1].ptr, callbacks.before, callbacks.after, callbacks.skip)
end

unhook = raw.unhook

local handlers = {}

function on(event, fn)
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], { fn = fn, errors = 0 })
  return fn
end

-- runs the handlers of an event with its arguments, one failing too often is disabled
local function emit(event, ...)
  for _, handler in ipairs(handlers[event] or {}) do
    if handler.errors < MAX_ERRORS then
      local ok, err = xpcall(handler.fn, debug.traceback, ...)
      if not ok then
        handler.errors = handler.errors + 1
        print(("%s handler failed%s: %s"):format(event, handler.errors == MAX_ERRORS and " (disabled)" or "", err))
      end
    end
  end
end

phigrospp.emit = emit

-- unity objects that died with their scene are forgotten
on("scene", function()
  local alive = {}
  for _, obj in ipairs(created) do
    if il2cpp.alive(obj) then alive[#alive + 1] = obj end
  end
  created = alive
end)

-- files: read whole, written through a temporary file so a crash never leaves half of one. bundle/<path> is a file of
-- the bundle, as built-in mods see theirs
function phigrospp.read(path)
  local bundled = path:match("^bundle/(.*)")
  if bundled then return phigrospp.bundle[bundled] or error("the bundle has no " .. bundled, 2) end
  local handle = assert(io.open(path, "rb"))
  local data = handle:read("a")
  handle:close()
  return data
end

function phigrospp.write(path, data)
  local handle = assert(io.open(path .. ".new", "wb"))
  handle:write(data)
  handle:close()
  assert(os.rename(path .. ".new", path))
end

-- a child by path, the error naming what the game no longer has
function phigrospp.find(root, path)
  return root:Find(path) or error(("%s has no child %s"):format(root.name, path), 2)
end

function __phigrospp_emit(event)
  emit(event)
  if event ~= "unload" then return end
  local Component = CS.UnityEngine.Component
  for _, obj in ipairs(created) do
    if il2cpp.alive(obj) then CS.UnityEngine.Object.Destroy(il2cpp.is(obj, Component) and obj.gameObject or obj) end
  end
end
