local M = {}

M.PERIODS = { 48, 96 }
M.COLORS = {
    { name = "black",  hex = "#1C1C1C", rgb = { 28, 28, 28 } },
    { name = "blue",   hex = "#1D4ED8", rgb = { 29, 78, 216 } },
    { name = "purple", hex = "#6D28D9", rgb = { 109, 40, 217 } },
    { name = "red",    hex = "#BE123C", rgb = { 190, 18, 60 } },
    { name = "orange", hex = "#B45309", rgb = { 180, 83, 9 } },
}

local GROUP_WIDTH = 16

local function read_utf8(s, i)
    local b = s:byte(i)
    local n = b < 0x80 and 1
        or b >= 0xC2 and b <= 0xDF and 2
        or b >= 0xE0 and b <= 0xEF and 3
        or b >= 0xF0 and b <= 0xF4 and 4
    if not n or i + n - 1 > #s then error("Invalid UTF-8") end
    local cp = b % (n == 1 and 0x80 or 2 ^ (7 - n))
    for j = i + 1, i + n - 1 do
        local c = s:byte(j)
        if c < 0x80 or c > 0xBF then error("Invalid UTF-8") end
        cp = cp * 0x40 + c - 0x80
    end
    if (n == 2 and cp < 0x80)
        or (n == 3 and cp < 0x800)
        or (n == 4 and cp < 0x10000)
        or cp > 0x10FFFF
        or (cp >= 0xD800 and cp <= 0xDFFF) then
        error("Invalid UTF-8")
    end
    return s:sub(i, i + n - 1), cp, i + n
end

local function is_combining(cp)
    return (cp >= 0x0300 and cp <= 0x036F)
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF)
        or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0xFE20 and cp <= 0xFE2F)
        or (cp >= 0xE0100 and cp <= 0xE01EF)
        or cp == 0x200D
end

local function is_space(cp)
    return cp == 0x09 or cp == 0x0A or cp == 0x0D or cp == 0x20
        or cp == 0x85 or cp == 0xA0 or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200A)
        or cp == 0x2028 or cp == 0x2029 or cp == 0x202F
        or cp == 0x205F or cp == 0x3000
end

-- Visible logical units: whitespace is ignored; punctuation counts; combining
-- marks, variation selectors and ZWJ stay attached to their preceding unit.
function M.units(s)
    local units = {}
    local i = 1
    local join_next = false
    while i <= #s do
        local bytes, cp, next_i = read_utf8(s, i)
        if is_combining(cp) and #units > 0 then
            units[#units] = units[#units] .. bytes
            if cp == 0x200D then join_next = true end
        elseif join_next and #units > 0 then
            units[#units] = units[#units] .. bytes
            join_next = false
        elseif not is_space(cp) then
            units[#units + 1] = bytes
        end
        i = next_i
    end
    return units
end

function M.count(s)
    return #M.units(s)
end

function M.bucket(index, period)
    assert(period == 48 or period == 96, "period must be 48 or 96")
    assert(type(index) == "number" and index >= 0 and index == math.floor(index), "invalid index")
    local steps = math.max(math.floor(period / GROUP_WIDTH), #M.COLORS)
    return math.floor((index % period) / period * steps)
end

function M.color(index, period)
    local steps = math.max(math.floor(period / GROUP_WIDTH), #M.COLORS)
    local x = M.bucket(index, period) * #M.COLORS / steps
    local a = math.floor(x) + 1
    local b = a % #M.COLORS + 1
    local t = x - math.floor(x)
    local rgb = {}
    for channel = 1, 3 do
        rgb[channel] = math.floor(M.COLORS[a].rgb[channel]
            + (M.COLORS[b].rgb[channel] - M.COLORS[a].rgb[channel]) * t + 0.5)
    end
    return string.format("#%02X%02X%02X", rgb[1], rgb[2], rgb[3])
end

local function add_fragment(out, box, first, last, total, logical_index, period)
    local width = box.x1 - box.x0
    local x0 = math.floor(box.x0 + width * (first - 1) / total + 0.5)
    local x1 = math.floor(box.x0 + width * last / total + 0.5)
    if x1 > x0 and box.y1 > box.y0 then
        out[#out + 1] = {
            x = x0,
            y = math.floor(box.y0 + 0.5),
            w = x1 - x0,
            h = math.max(1, math.floor(box.y1 - box.y0 + 0.5)),
            color = M.color(logical_index + first - 1, period),
        }
    end
end

-- Converts KOReader's line/word boxes into coalesced color rectangles.
-- Width is divided evenly among logical units. This is exact for equal-width
-- CJK text and provisional for proportional Latin text and RTL scripts.
function M.fragments(lines, base_index, period)
    assert(period == 48 or period == 96, "period must be 48 or 96")
    local out = {}
    local logical_index = base_index or 0
    for _, line in ipairs(lines or {}) do
        for _, box in ipairs(line) do
            local units = M.units(box.word or "")
            local total = #units
            if total > 0 and box.x0 and box.x1 and box.y0 and box.y1 then
                local run_first = 1
                local run_bucket = M.bucket(logical_index, period)
                for i = 2, total do
                    local bucket = M.bucket(logical_index + i - 1, period)
                    if bucket ~= run_bucket then
                        add_fragment(out, box, run_first, i - 1, total, logical_index, period)
                        run_first = i
                        run_bucket = bucket
                    end
                end
                add_fragment(out, box, run_first, total, total, logical_index, period)
                logical_index = logical_index + total
            end
        end
    end
    return out, logical_index
end

return M
