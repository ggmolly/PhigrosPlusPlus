-- phigrospp.ui.icon(name): a Lucide icon (lucide.dev) as a white sprite, tinted by the Image showing it. the icons are
-- the markup of lucide-static 1.60.0's svg files, its license is at the end. a mod can give another one's svg instead

local SIZE, STROKE = 96, 1.5 -- pixels, and the stroke width in lucide's 24 by 24 box, thinner than its 2 like the game's
local CURVE, ARC = 8, math.pi / 16 -- segments per curve, and radians per arc segment

local LUCIDE = {
  ["arrow-left"] = [[<path d="m12 19-7-7 7-7" /><path d="M19 12H5" />]],
  clock = [[<circle cx="12" cy="12" r="10" /><path d="M12 6v6l4 2" />]],
  ["fast-forward"] = [[<path d="M12 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 12 18z" />
    <path d="M2 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 2 18z" />]],
  pause = [[<rect x="14" y="3" width="5" height="18" rx="1" /><rect x="5" y="3" width="5" height="18" rx="1" />]],
  play = [[<path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" />]],
  rewind = [[<path d="M12 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 12 18z" />
    <path d="M22 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 22 18z" />]],
  ["skip-back"] = [[<path d="M17.971 4.285A2 2 0 0 1 21 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z" />
    <path d="M3 20V4" />]],
  square = [[<rect width="18" height="18" x="3" y="3" rx="2" />]],
  ["square-check"] = [[<rect width="18" height="18" x="3" y="3" rx="2" /><path d="m16 9-5.5 5.5L8 12" />]],
  ["trash-2"] = [[<path d="M10 11v6" /><path d="M14 11v6" /><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
    <path d="M3 6h18" /><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />]],
  trophy = [[<path d="M10 14.66V17a1 1 0 0 1-1 1 2 2 0 0 0-2 2v2" /><path d="M14 14.66V17a1 1 0 0 0 1 1 2 2 0 0 1 2 2v2" />
    <path d="M17.916 10H19.5A2.5 2.5 0 0 0 22 7.5V5a1 1 0 0 0-1-1h-3" /><path d="M4 22h16" />
    <path d="M6 9a6 6 0 0 0 12 0V3a1 1 0 0 0-1-1H7a1 1 0 0 0-1 1z" /><path d="M6.084 10H4.5A2.5 2.5 0 0 1 2 7.5V5a1 1 0 0 1 1-1h3" />]],
  x = [[<path d="M18 6 6 18" /><path d="m6 6 12 12" />]],
}

local function ellipse(cx, cy, rx, ry)
  return ("M%g %ga%g %g 0 1 0 %g 0a%g %g 0 1 0 %g 0"):format(cx - rx, cy, rx, ry, 2 * rx, rx, ry, -2 * rx)
end

-- every element drawn, as path data. others (the svg element around them) aren't drawn
local ELEMENTS = {
  path = function(a) return a.d end,
  line = function(a) return ("M%g %gL%g %g"):format(a.x1, a.y1, a.x2, a.y2) end,
  polyline = function(a) return "M" .. a.points end,
  polygon = function(a) return "M" .. a.points .. "z" end,
  circle = function(a) return ellipse(a.cx, a.cy, a.r, a.r) end,
  ellipse = function(a) return ellipse(a.cx, a.cy, a.rx, a.ry) end,
  rect = function(a)
    local x, y, w, h = a.x or 0, a.y or 0, a.width, a.height
    local rx, ry = math.min(a.rx or a.ry or 0, w / 2), math.min(a.ry or a.rx or 0, h / 2)
    local corner = ("a%g %g 0 0 1 %%g %%g"):format(rx, ry)
    return ("M%g %gh%g" .. corner .. "v%g" .. corner .. "h%g" .. corner .. "v%g" .. corner .. "z"):format(x + rx, y,
      w - 2 * rx, rx, ry, h - 2 * ry, -rx, ry, 2 * rx - w, -rx, -ry, 2 * ry - h, rx, -ry)
  end,
}

local ARGS = { m = 2, l = 2, h = 1, v = 1, c = 6, s = 4, q = 4, t = 2, a = 7, z = 0 }

-- the straight segments { ax, ay, bx, by } a path's data draws, curves and arcs cut into short ones
local function trace(d, segments)
  local x, y, sx, sy, cx, cy, qx, qy = 0, 0, 0, 0, 0, 0, 0, 0
  local function to(nx, ny)
    segments[#segments + 1] = { x, y, nx, ny }
    x, y = nx, ny
  end
  local function cubic(ax, ay, bx, by, ex, ey)
    local x0, y0 = x, y
    for i = 1, CURVE do
      local t = i / CURVE
      local u = 1 - t
      to(u ^ 3 * x0 + 3 * u * u * t * ax + 3 * u * t * t * bx + t ^ 3 * ex,
        u ^ 3 * y0 + 3 * u * u * t * ay + 3 * u * t * t * by + t ^ 3 * ey)
    end
    cx, cy = bx, by
  end
  local function quadratic(ax, ay, ex, ey)
    cubic(x + (ax - x) * 2 / 3, y + (ay - y) * 2 / 3, ex + (ax - ex) * 2 / 3, ey + (ay - ey) * 2 / 3, ex, ey)
    qx, qy = ax, ay
  end
  -- the svg 2 spec's endpoint to centre conversion (appendix b.2.4): the ellipse's centre and the angles it turns through
  local function arc(rx, ry, angle, large, sweep, ex, ey)
    if x == ex and y == ey then return end
    if rx == 0 or ry == 0 then return to(ex, ey) end
    local cos, sin = math.cos(math.rad(angle)), math.sin(math.rad(angle))
    local dx, dy = (x - ex) / 2, (y - ey) / 2
    local px, py = cos * dx + sin * dy, cos * dy - sin * dx
    local grow = math.sqrt(math.max(1, px * px / (rx * rx) + py * py / (ry * ry))) -- too small radii are scaled up
    rx, ry = math.abs(rx) * grow, math.abs(ry) * grow
    local k = math.sqrt(math.max(0, (rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px)
      / (rx * rx * py * py + ry * ry * px * px)))
    if large == sweep then k = -k end
    local ox, oy = k * rx * py / ry, -k * ry * px / rx
    local mx, my = cos * ox - sin * oy + (x + ex) / 2, sin * ox + cos * oy + (y + ey) / 2
    local from = math.atan((py - oy) / ry, (px - ox) / rx)
    local turn = math.atan((-py - oy) / ry, (-px - ox) / rx) - from
    if sweep == 1 and turn < 0 then turn = turn + 2 * math.pi end
    if sweep == 0 and turn > 0 then turn = turn - 2 * math.pi end
    local steps = math.ceil(math.abs(turn) / ARC)
    for i = 1, steps do
      local a = from + turn * i / steps
      local ux, uy = rx * math.cos(a), ry * math.sin(a)
      to(mx + cos * ux - sin * uy, my + sin * ux + cos * uy)
    end
  end
  for letter, args in d:gmatch("(%a)([^%a]*)") do
    local command, relative, n, i = letter:lower(), letter:match("%l") ~= nil, {}, 1
    for number in args:gmatch("[-+]?%d*%.?%d+") do n[#n + 1] = tonumber(number) end
    repeat
      local a, ox, oy = { table.unpack(n, i, i + ARGS[command] - 1) }, relative and x or 0, relative and y or 0
      i = i + ARGS[command]
      if command == "m" then
        x, y = ox + a[1], oy + a[2]
        sx, sy, command = x, y, "l" -- the pairs after a move draw lines
      elseif command == "l" then to(ox + a[1], oy + a[2])
      elseif command == "h" then to(ox + a[1], y)
      elseif command == "v" then to(x, oy + a[1])
      elseif command == "c" then cubic(ox + a[1], oy + a[2], ox + a[3], oy + a[4], ox + a[5], oy + a[6])
      elseif command == "s" then cubic(2 * x - cx, 2 * y - cy, ox + a[1], oy + a[2], ox + a[3], oy + a[4])
      elseif command == "q" then quadratic(ox + a[1], oy + a[2], ox + a[3], oy + a[4])
      elseif command == "t" then quadratic(2 * x - qx, 2 * y - qy, ox + a[1], oy + a[2])
      elseif command == "a" then arc(a[1], a[2], a[3], a[4], a[5], ox + a[6], oy + a[7])
      else to(sx, sy) end
      -- s and t mirror the last curve's control point, or start from the pen after anything else
      if command ~= "c" and command ~= "s" then cx, cy = x, y end
      if command ~= "q" and command ~= "t" then qx, qy = x, y end
    until i > #n
  end
end

-- the distance to the nearest segment minus half the stroke, in the sprite's pixels (see phigrospp.sprite). a segment
-- is skipped when the pixel is out of its box grown by the stroke, it can't touch the pixel
local function shape(markup)
  local segments, scale = {}, SIZE / 24
  for name, attributes in markup:gmatch("<(%a+)(.-)/?>") do
    local a = {}
    for key, value in attributes:gmatch('([%w-]+)="([^"]*)"') do a[key] = tonumber(value) or value end
    if ELEMENTS[name] then trace(ELEMENTS[name](a), segments) end
  end
  local half = STROKE * scale / 2
  local reach = half + 1
  for i, s in ipairs(segments) do
    -- lucide's y goes down, a texture's up
    local ax, ay, bx, by = s[1] * scale - SIZE / 2, SIZE / 2 - s[2] * scale, s[3] * scale - SIZE / 2, SIZE / 2 - s[4] * scale
    segments[i] = { ax, ay, bx - ax, by - ay, math.min(ax, bx) - reach, math.max(ax, bx) + reach,
      math.min(ay, by) - reach, math.max(ay, by) + reach }
  end
  -- phigrospp.sprite goes row by row, so the segments a row can touch are found once per row
  local row, near
  return function(x, y)
    if y ~= row then
      row, near = y, {}
      for _, s in ipairs(segments) do
        if y > s[7] and y < s[8] then near[#near + 1] = s end
      end
    end
    local nearest = reach
    for _, s in ipairs(near) do
      if x > s[5] and x < s[6] then
        local ex, ey, dx, dy = x - s[1], y - s[2], s[3], s[4]
        local length = dx * dx + dy * dy
        local t = length > 0 and math.max(0, math.min(1, (ex * dx + ey * dy) / length)) or 0
        nearest = math.min(nearest, math.sqrt((ex - t * dx) ^ 2 + (ey - t * dy) ^ 2))
      end
    end
    return nearest - half
  end
end

local icons = {}

function phigrospp.ui.icon(name)
  icons[name] = icons[name] or phigrospp.sprite(SIZE, shape(LUCIDE[name] or name))
  return icons[name]
end

--[[
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

The arrow-left, clock, square, trash-2 and x icons are derived from the Feather project:

The MIT License (MIT)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]
