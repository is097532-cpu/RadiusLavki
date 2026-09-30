--[[
    RadiusLavki 5.2
    Идея и оригинал: Alex07 (RadiusLavki 3.0)
    Переделка: Hole_Digger

    Показывает, где можно поставить переносную лавку:
      - сплошная синяя заливка земли с ровными краями там, где до всех лавок
        дальше RADIUS метров;
      - кружок под тобой и подсказка внизу экрана;
      - стрелка к ближайшему свободному месту;
      - звук, когда встал на свободное место;
      - автовыключение после того, как поставил лавку;
      - меню настроек с сохранением в конфиг;
      - автообновление с GitHub.

    Команды:
      /rlavka         - включить / выключить показ (или ALT + 3)
      /rlavka menu    - меню настроек (или /rlmenu)
      /rlupdate       - проверить обновление вручную
]]

script_name('RadiusLavki')
script_author('Alex07', 'Hole_Digger')
script_version('5.2')

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local vkeys    = require 'vkeys'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ================= КОНФИГ =================
local CFG_FILE = 'RadiusLavki.ini'
local DEFAULTS = {
    radius = 5.0, area = 12.0, cell = 0.8,
    arrow = true, sound = true, autoOff = true, hotkey = true, autoUpdate = true,
    fillR = 0.24, fillG = 0.48, fillB = 1.00, fillA = 0.45,
    arrR  = 1.00, arrG  = 1.00, arrB  = 1.00, arrA  = 1.00,
}
local cfg = inicfg.load({ main = DEFAULTS }, CFG_FILE)
for k, def in pairs(DEFAULTS) do
    if cfg.main[k] == nil then cfg.main[k] = def end
end

local v = {
    radius  = imgui.new.float(cfg.main.radius),
    area    = imgui.new.float(cfg.main.area),
    cell    = imgui.new.float(cfg.main.cell),
    arrow   = imgui.new.bool(cfg.main.arrow),
    sound   = imgui.new.bool(cfg.main.sound),
    autoOff = imgui.new.bool(cfg.main.autoOff),
    hotkey  = imgui.new.bool(cfg.main.hotkey),
    autoUpd = imgui.new.bool(cfg.main.autoUpdate),
    fillCol = imgui.new.float[4](cfg.main.fillR, cfg.main.fillG, cfg.main.fillB, cfg.main.fillA),
    arrCol  = imgui.new.float[4](cfg.main.arrR,  cfg.main.arrG,  cfg.main.arrB,  cfg.main.arrA),
}

local dirtySince = nil -- сохраняем не на каждое движение ползунка, а через секунду
local function markDirty()
    local m = cfg.main
    m.radius, m.area, m.cell = v.radius[0], v.area[0], v.cell[0]
    m.arrow, m.sound = v.arrow[0], v.sound[0]
    m.autoOff, m.hotkey = v.autoOff[0], v.hotkey[0]
    m.autoUpdate = v.autoUpd[0]
    m.fillR, m.fillG, m.fillB, m.fillA = v.fillCol[0], v.fillCol[1], v.fillCol[2], v.fillCol[3]
    m.arrR,  m.arrG,  m.arrB,  m.arrA  = v.arrCol[0],  v.arrCol[1],  v.arrCol[2],  v.arrCol[3]
    dirtySince = os.clock()
end

local function resetAll()
    local d = DEFAULTS
    v.radius[0], v.area[0], v.cell[0] = d.radius, d.area, d.cell
    v.arrow[0], v.sound[0], v.autoOff[0], v.hotkey[0] = d.arrow, d.sound, d.autoOff, d.hotkey
    v.autoUpd[0] = d.autoUpdate
    v.fillCol[0], v.fillCol[1], v.fillCol[2], v.fillCol[3] = d.fillR, d.fillG, d.fillB, d.fillA
    v.arrCol[0],  v.arrCol[1],  v.arrCol[2],  v.arrCol[3]  = d.arrR,  d.arrG,  d.arrB,  d.arrA
    markDirty()
end

-- ================= СОСТОЯНИЕ =================
local STALL_TEXT = "Управления товарами."
local PREFIX = "{5A8CFF}[RadiusLavki]{FFFFFF} "

local active = false
local menuOpen = imgui.new.bool(false)
local stalls = {}          -- кэш лавок: { {x, y}, ... }, обновляется 3 раза в секунду
local baselineNeeded = true
local lastOk = nil         -- для звука при переходе «нельзя -> можно»

local function msg(text) sampAddChatMessage(PREFIX .. text, -1) end

local function setActive(state)
    active = state
    baselineNeeded = true
    lastOk = nil
    msg("Показ места под лавку: " .. (active and "{30D085}ВКЛ" or "{F05A5A}ВЫКЛ"))
end

-- ================= АВТООБНОВЛЕНИЕ =================
-- Замени USER и REPO на свои (ник на GitHub и название репозитория).
-- В update.json лежит номер последней версии и ссылка на сам скрипт.
local UPDATE_JSON = 'https://raw.githubusercontent.com/is097532-cpu/RadiusLavki/main/update.json'

local dlstatus = require('moonloader').download_status
local update = { busy = false, text = '' }

-- true, если версия remote новее current ("5.10" > "5.9", "5.2.1" > "5.2")
local function versionNewer(remote, current)
    local r, c = {}, {}
    for n in tostring(remote):gmatch('%d+') do r[#r + 1] = tonumber(n) end
    for n in tostring(current):gmatch('%d+') do c[#c + 1] = tonumber(n) end
    for i = 1, math.max(#r, #c) do
        local a, b = r[i] or 0, c[i] or 0
        if a ~= b then return a > b end
    end
    return false
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

-- Качает файл и ждёт окончания. Вызывать только внутри lua_thread.
local function downloadWait(url, path, timeout)
    if doesFileExist(path) then os.remove(path) end
    local done = false
    downloadUrlToFile(url, path, function(id, status)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then done = true end
    end)
    local start = os.clock()
    while not done do
        if os.clock() - start > (timeout or 15) then return false end
        wait(100)
    end
    return doesFileExist(path)
end

local function checkUpdate(manual)
    if update.busy then return end
    update.busy = true
    lua_thread.create(function()
        local function fail(text)
            update.text, update.busy = text, false
            if manual then msg('{F05A5A}' .. text) end
        end

        update.text = 'Проверяю...'
        -- ?t=... чтобы GitHub не отдавал старую копию из кэша
        local tmp = os.getenv('TEMP') .. '\\RadiusLavki_update.json'
        if not downloadWait(UPDATE_JSON .. '?t=' .. os.time(), tmp) then
            return fail('Не удалось связаться с GitHub')
        end
        local ok, info = pcall(decodeJson, readFile(tmp) or '')
        os.remove(tmp)
        if not ok or type(info) ~= 'table' or not info.version or not info.url then
            return fail('Файл update.json не найден или сломан')
        end

        local cur = thisScript().version
        if not versionNewer(info.version, cur) then
            update.text, update.busy = 'Установлена последняя версия', false
            if manual then msg('У тебя последняя версия {30D085}' .. cur) end
            return
        end

        update.text = 'Загружаю ' .. info.version .. '...'
        msg('Найдено обновление {30D085}' .. cur .. ' -> ' .. info.version .. '{FFFFFF}, загружаю...')
        local newPath = thisScript().path .. '.new'
        if not downloadWait(info.url .. '?t=' .. os.time(), newPath, 30) then
            os.remove(newPath)
            return fail('Не удалось скачать новую версию')
        end
        local body = readFile(newPath) or ''
        os.remove(newPath)
        -- защита от записи страницы с ошибкой (404 и т.п.) поверх скрипта
        if not body:find("script_name%('RadiusLavki'%)") then
            return fail('Скачанный файл повреждён, обновление отменено')
        end

        local f = io.open(thisScript().path, 'wb')
        if not f then return fail('Нет доступа к файлу скрипта') end
        f:write(body)
        f:close()

        if info.changes then msg('Что нового: ' .. u8:decode(tostring(info.changes))) end
        msg('Обновлено до {30D085}' .. info.version .. '{FFFFFF}, перезапускаю...')
        if dirtySince then inicfg.save(cfg, CFG_FILE) end
        wait(500)
        thisScript():reload()
    end)
end

-- ================= ГЕОМЕТРИЯ =================
local function isCentralMarket(x, y)
    return x > 1090 and x < 1180 and y > -1550 and y < -1429
end

local function groundZ(x, y, z)
    local ok, gz = pcall(getGroundZFor3dCoord, x, y, z)
    if ok and type(gz) == "number" and gz ~= 0 and math.abs(gz - z) < 5 then
        return gz + 0.05
    end
    return z - 1.0
end

local function toScreen(x, y, z)
    local _, sx, sy, sz = convert3DCoordsToScreenEx(x, y, z)
    if sz and sz > 1 then return imgui.ImVec2(sx, sy) end
    return nil
end

local function nearestStall(x, y, skip)
    local best = math.huge
    for i = 1, #stalls do
        if i ~= skip then
            local dx, dy = x - stalls[i][1], y - stalls[i][2]
            local d = dx * dx + dy * dy
            if d < best then best = d end
        end
    end
    return math.sqrt(best)
end

local function refreshStalls()
    local list = {}
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, _, x, y = sampGet3dTextInfoById(id)
            if text == STALL_TEXT and not isCentralMarket(x, y) then
                list[#list + 1] = { x, y }
            end
        end
    end

    -- автовыключение: рядом с тобой (до 2.5 м) появилась новая лавка = ты её поставил
    if active and v.autoOff[0] and not baselineNeeded then
        local px, py = getCharCoordinates(PLAYER_PED)
        for _, s in ipairs(list) do
            local isNew = true
            for _, old in ipairs(stalls) do
                if math.abs(old[1] - s[1]) < 0.3 and math.abs(old[2] - s[2]) < 0.3 then isNew = false; break end
            end
            if isNew and math.sqrt((s[1] - px) ^ 2 + (s[2] - py) ^ 2) <= 2.5 then
                stalls = list
                active = false
                msg("Лавка поставлена, показ выключен. Включить снова: /rlavka")
                return
            end
        end
    end
    baselineNeeded = false
    stalls = list
end

-- ================= ЦВЕТА И ШРИФТЫ =================
local function V2(x, y) return imgui.ImVec2(x, y) end
local function V4(r, g, b, a) return imgui.ImVec4(r, g, b, a or 1) end
local function U32(c) return imgui.ColorConvertFloat4ToU32(c) end
local function colFrom(arr, mulA) return U32(V4(arr[0], arr[1], arr[2], arr[3] * (mulA or 1))) end

local C = {
    bg         = V4(0.067, 0.071, 0.086, 0.98),
    card       = V4(0.106, 0.112, 0.137, 1.00),
    cardBorder = V4(1.00, 1.00, 1.00, 0.06),
    frame      = V4(0.150, 0.158, 0.192, 1.00),
    frameHov   = V4(0.185, 0.195, 0.235, 1.00),
    frameAct   = V4(0.215, 0.228, 0.275, 1.00),
    accent     = V4(0.36, 0.55, 1.00, 1.00),
    accentHov  = V4(0.46, 0.63, 1.00, 1.00),
    text       = V4(0.93, 0.94, 0.96, 1.00),
    textDim    = V4(0.56, 0.59, 0.66, 1.00),
    success    = V4(0.30, 0.82, 0.52, 1.00),
    danger     = V4(0.96, 0.37, 0.39, 1.00),
    hudBg      = V4(0.067, 0.078, 0.094, 0.82),
}
local WHITE = V4(1, 1, 1, 1)
local function alpha(c, a) return V4(c.x, c.y, c.z, c.w * a) end
local function mix(a, b, t)
    return V4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
end

local fonts = {}
local styleApplied = false
local fillAAFlag = nil     -- флаг сглаживания заливки у draw list (если есть в этой сборке mimgui)

local function applyCustomStyle()
    local style = imgui.GetStyle()
    style.WindowRounding, style.ChildRounding, style.FrameRounding = 14.0, 10.0, 8.0
    style.PopupRounding, style.ScrollbarRounding, style.GrabRounding = 8.0, 8.0, 8.0
    style.WindowPadding, style.FramePadding = V2(16, 16), V2(12, 8)
    style.ItemSpacing, style.ItemInnerSpacing = V2(10, 8), V2(8, 6)
    style.WindowBorderSize, style.ChildBorderSize, style.FrameBorderSize, style.PopupBorderSize = 0, 1, 0, 0
    style.ScrollbarSize, style.GrabMinSize = 8, 14

    local colors = style.Colors
    local function setColor(name, c)
        local idx = imgui.Col[name]
        if idx ~= nil then colors[idx] = c end
    end
    setColor('Text', C.text);             setColor('TextDisabled', C.textDim)
    setColor('WindowBg', C.bg);           setColor('ChildBg', C.card)
    setColor('PopupBg', C.bg);            setColor('Border', C.cardBorder)
    setColor('FrameBg', C.frame);         setColor('FrameBgHovered', C.frameHov)
    setColor('FrameBgActive', C.frameAct)
    setColor('ScrollbarBg', V4(0, 0, 0, 0))
    setColor('ScrollbarGrab', V4(1, 1, 1, 0.10))
    setColor('ScrollbarGrabHovered', V4(1, 1, 1, 0.18))
    setColor('ScrollbarGrabActive', C.accent)
    setColor('SliderGrab', C.accent);     setColor('SliderGrabActive', C.accentHov)
    setColor('Button', C.frame);          setColor('ButtonHovered', C.frameHov)
    setColor('ButtonActive', C.frameAct)
    setColor('TextSelectedBg', alpha(C.accent, 0.35))
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local ok = pcall(function()
        local dir = getFolderPath(0x14) -- Windows\Fonts
        local reg = dir .. "\\segoeui.ttf"
        local bold = dir .. "\\seguisb.ttf"
        if not doesFileExist(bold) then bold = dir .. "\\segoeuib.ttf" end
        if not doesFileExist(reg) then reg = dir .. "\\arial.ttf" end
        if not doesFileExist(reg) then return end
        if not doesFileExist(bold) then bold = reg end
        local ranges = io.Fonts:GetGlyphRangesCyrillic()
        io.Fonts:Clear()
        fonts.regular = io.Fonts:AddFontFromFileTTF(reg, 16.0, nil, ranges)
        fonts.bold    = io.Fonts:AddFontFromFileTTF(bold, 16.0, nil, ranges)
        fonts.title   = io.Fonts:AddFontFromFileTTF(bold, 21.0, nil, ranges)
    end)
    if not ok then fonts = {} end

    -- Заливку клеток рисуем без сглаживания, иначе между ними видна сетка.
    -- Если в этой сборке нет нужного флага, отключаем сглаживание заливки целиком.
    local okFlag, flag = pcall(function() return imgui.DrawListFlags.AntiAliasedFill end)
    if okFlag and type(flag) == "number" then
        fillAAFlag = flag
    else
        pcall(function() imgui.GetStyle().AntiAliasedFill = false end)
    end

    applyCustomStyle()
    styleApplied = true
end)

local function withFont(font, fn)
    if font then imgui.PushFont(font) end
    fn()
    if font then imgui.PopFont() end
end

-- ================= ОТРИСОВКА ЗОН =================
-- «Поле»: > 0 там, где лавку ставить можно. Это расстояние до ближайшей
-- запрещённой границы: до края чужой зоны или до края области показа.
local function fieldAt(x, y, px, py, R, A)
    local f = A - math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
    for i = 1, #stalls do
        local d = math.sqrt((x - stalls[i][1]) ^ 2 + (y - stalls[i][2]) ^ 2) - R
        if d < f then f = d end
    end
    return f
end

-- Сплошная заливка с ровными краями (алгоритм marching squares):
-- клетки целиком внутри закрашиваются квадратом, а у пограничных клеток
-- край срезается точно по окружности, поэтому никаких «ступенек».
local function drawAllowedArea(dl, px, py, gz)
    local R, A, cell = v.radius[0], v.area[0], math.max(0.3, v.cell[0])
    local n = math.ceil(A / cell) + 1
    local baseX = math.floor(px / cell) * cell  -- сетка привязана к миру, не «плывёт» при ходьбе
    local baseY = math.floor(py / cell) * cell
    local col = colFrom(v.fillCol)

    -- значения поля в узлах сетки + ближайшая к игроку свободная точка (для стрелки)
    local F, S = {}, {}
    local best, bestD = nil, math.huge
    for i = -n, n + 1 do
        local fr = {}
        for j = -n, n + 1 do
            local x, y = baseX + i * cell, baseY + j * cell
            local f = fieldAt(x, y, px, py, R, A)
            fr[j] = f
            if f > 0.3 then
                local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
                if d < bestD then best, bestD = { x, y }, d end
            end
        end
        F[i], S[i] = fr, {}
    end

    local function node(i, j)
        local s = S[i][j]
        if s == nil then
            s = toScreen(baseX + i * cell, baseY + j * cell, gz) or false
            S[i][j] = s
        end
        return s
    end

    local ci = { 0, 1, 1, 0 }
    local cj = { 0, 0, 1, 1 }
    for i = -n, n do
        for j = -n, n do
            local f1, f2, f3, f4 = F[i][j], F[i + 1][j], F[i + 1][j + 1], F[i][j + 1]
            if f1 > 0 and f2 > 0 and f3 > 0 and f4 > 0 then
                local p1, p2, p3, p4 = node(i, j), node(i + 1, j), node(i + 1, j + 1), node(i, j + 1)
                if p1 and p2 and p3 and p4 then dl:AddQuadFilled(p1, p2, p3, p4, col) end
            elseif f1 > 0 or f2 > 0 or f3 > 0 or f4 > 0 then
                local fv = { f1, f2, f3, f4 }
                local poly, valid = {}, true
                for k = 1, 4 do
                    local m = k % 4 + 1
                    local fa, fb = fv[k], fv[m]
                    if fa > 0 then
                        local p = node(i + ci[k], j + cj[k])
                        if not p then valid = false; break end
                        poly[#poly + 1] = p
                    end
                    if (fa > 0) ~= (fb > 0) then
                        local t = fa / (fa - fb)
                        local xa, ya = baseX + (i + ci[k]) * cell, baseY + (j + cj[k]) * cell
                        local xb, yb = baseX + (i + ci[m]) * cell, baseY + (j + cj[m]) * cell
                        local p = toScreen(xa + (xb - xa) * t, ya + (yb - ya) * t, gz)
                        if not p then valid = false; break end
                        poly[#poly + 1] = p
                    end
                end
                if valid and #poly >= 3 then
                    for k = 2, #poly - 1 do
                        dl:AddTriangleFilled(poly[1], poly[k], poly[k + 1], col)
                    end
                end
            end
        end
    end
    return best, bestD
end

local function hudLabel(dl, pos, text, dotCol)
    local ts = imgui.CalcTextSize(text)
    local x, y = pos.x - ts.x / 2, pos.y - ts.y / 2
    local padL = dotCol and 22 or 12
    dl:AddRectFilled(V2(x - padL, y - 7), V2(x + ts.x + 12, y + ts.y + 7), U32(C.hudBg), 10)
    if dotCol then dl:AddCircleFilled(V2(x - 10, y + ts.y / 2), 4, dotCol, 12) end
    dl:AddText(V2(x, y), U32(WHITE), text)
end

local function drawArrow(dl, px, py, bx, by, gz, dist)
    local col = colFrom(v.arrCol)
    local p0, p1 = toScreen(px, py, gz), toScreen(bx, by, gz)
    if not (p0 and p1) then return end
    dl:AddLine(p0, p1, col, 3.0)
    local dx, dy = bx - px, by - py
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0.05 then
        dx, dy = dx / len, dy / len
        for _, ang in ipairs({ math.rad(150), math.rad(-150) }) do
            local wx = bx + (dx * math.cos(ang) - dy * math.sin(ang)) * 0.7
            local wy = by + (dx * math.sin(ang) + dy * math.cos(ang)) * 0.7
            local w = toScreen(wx, wy, gz)
            if w then dl:AddLine(p1, w, col, 3.0) end
        end
    end
    dl:AddCircleFilled(p1, 5, col, 16)
    hudLabel(dl, V2(p1.x, p1.y - 26), u8(("%.1f м"):format(dist)))
end

local function drawPlayerMarker(dl, px, py, gz, ok)
    local col = ok and colFrom(v.fillCol, 1 / math.max(v.fillCol[3], 0.01)) or U32(C.danger)
    local fill = ok and colFrom(v.fillCol, 1.2) or U32(alpha(C.danger, 0.45))
    local c = toScreen(px, py, gz)
    local pts = {}
    for k = 0, 24 do
        local a = k / 24 * math.pi * 2
        pts[k] = toScreen(px + 0.45 * math.cos(a), py + 0.45 * math.sin(a), gz) or false
    end
    for k = 0, 23 do
        if pts[k] and pts[k + 1] then
            if c then dl:AddTriangleFilled(c, pts[k], pts[k + 1], fill) end
            dl:AddLine(pts[k], pts[k + 1], col, 2.0)
        end
    end
    return col
end

local function drawOverlay()
    local dl = imgui.GetBackgroundDrawList()
    if fillAAFlag then
        pcall(function() dl.Flags = bit.band(dl.Flags, bit.bnot(fillAAFlag)) end)
    end

    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local gz = groundZ(px, py, pz)
    local R = v.radius[0]

    local best, bestD = drawAllowedArea(dl, px, py, gz)

    local dist = nearestStall(px, py)
    local ok = dist > R
    local markerCol = drawPlayerMarker(dl, px, py, gz, ok)

    if not ok and v.arrow[0] and best then drawArrow(dl, px, py, best[1], best[2], gz, bestD) end

    if ok and lastOk == false and v.sound[0] then pcall(addOneOffSound, 0.0, 0.0, 0.0, 1139) end
    lastOk = ok

    local text
    if ok then
        text = dist == math.huge and "Можно ставить лавку (рядом лавок нет)"
            or ("Можно ставить лавку (до ближайшей %.1f м)"):format(dist)
    elseif best then
        text = ("Нельзя: до лавки %.1f м. Свободное место в %.1f м"):format(dist, bestD)
    else
        text = ("Нельзя: до лавки %.1f м. Рядом свободного места нет"):format(dist)
    end
    local resX, resY = getScreenResolution()
    hudLabel(dl, V2(resX / 2, resY - 170), u8(text), markerCol)
end

-- ================= ВИДЖЕТЫ МЕНЮ =================
local toggleAnim, cardHeights = {}, {}

local function StyledButton(label, size, kind)
    local base, hov, act, txt
    if kind == 'primary' then
        base, hov, act, txt = C.accent, C.accentHov, C.accent, WHITE
    elseif kind == 'danger' then
        base, hov, act, txt = alpha(C.danger, 0.14), alpha(C.danger, 0.24), alpha(C.danger, 0.34), C.danger
    else
        base, hov, act, txt = C.frame, C.frameHov, C.frameAct, C.text
    end
    imgui.PushStyleColor(imgui.Col.Button, base)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, hov)
    imgui.PushStyleColor(imgui.Col.ButtonActive, act)
    imgui.PushStyleColor(imgui.Col.Text, txt)
    local clicked = imgui.Button(label, size or V2(0, 0))
    imgui.PopStyleColor(4)
    return clicked
end

local function FieldLabel(text)
    imgui.PushStyleColor(imgui.Col.Text, C.textDim)
    imgui.TextWrapped(text)
    imgui.PopStyleColor()
end

local function BeginCard(id, title)
    imgui.PushStyleColor(imgui.Col.ChildBg, C.card)
    imgui.PushStyleColor(imgui.Col.Border, C.cardBorder)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V2(16, 14))
    imgui.BeginChild(id, V2(-1, cardHeights[id] or 120), true,
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
    if title then
        withFont(fonts.bold, function() imgui.Text(title) end)
        imgui.Dummy(V2(0, 2))
    end
end

local function EndCard(id)
    cardHeights[id] = imgui.GetCursorPosY() - imgui.GetStyle().ItemSpacing.y + 14
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
    imgui.Dummy(V2(0, 2))
end

-- state: imgui.new.bool или обычный true/false (тогда действие делаешь сам по клику)
local function Toggle(id, label, desc, state)
    local isPtr = type(state) ~= 'boolean'
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local availW = imgui.GetContentRegionAvail().x
    local tw, th = 40, 22
    local lineH = imgui.GetTextLineHeight()
    local rowH = math.max(th, desc and (lineH * 2 + 2) or lineH)

    local clicked = imgui.InvisibleButton(id, V2(availW, rowH))
    if clicked and isPtr then state[0] = not state[0] end
    local value
    if isPtr then value = state[0] else value = state end
    local hovered = imgui.IsItemHovered()

    local target = value and 1 or 0
    local t = toggleAnim[id] or target
    local step = imgui.GetIO().DeltaTime * 9
    if t < target then t = math.min(target, t + step) elseif t > target then t = math.max(target, t - step) end
    toggleAnim[id] = t

    if desc then
        dl:AddText(V2(p.x, p.y), U32(C.text), label)
        dl:AddText(V2(p.x, p.y + lineH + 2), U32(C.textDim), desc)
    else
        dl:AddText(V2(p.x, p.y + (rowH - lineH) / 2), U32(C.text), label)
    end
    local sx, sy = p.x + availW - tw, p.y + (rowH - th) / 2
    dl:AddRectFilled(V2(sx, sy), V2(sx + tw, sy + th), U32(mix(hovered and C.frameHov or C.frame, C.accent, t)), th / 2)
    dl:AddCircleFilled(V2(sx + th / 2 + t * (tw - th), sy + th / 2), th / 2 - 3, U32(WHITE), 20)
    return clicked
end

local function ColorRow(label, id, col)
    local startX = imgui.GetCursorPosX()
    local availW = imgui.GetContentRegionAvail().x
    imgui.AlignTextToFramePadding()
    imgui.Text(label)
    imgui.SameLine(startX + availW - 36)
    if imgui.ColorEdit4(id, col, imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel
        + imgui.ColorEditFlags.AlphaBar) then
        markDirty()
    end
end

local function Slider(id, label, ptr, minV, maxV, fmt)
    FieldLabel(label)
    imgui.PushItemWidth(-1)
    if imgui.SliderFloat(id, ptr, minV, maxV, fmt) then markDirty() end
    imgui.PopItemWidth()
end

local function CloseButton(id, pos, size)
    local dl = imgui.GetWindowDrawList()
    imgui.SetCursorScreenPos(pos)
    local clicked = imgui.InvisibleButton(id, V2(size, size))
    local hovered = imgui.IsItemHovered()
    if hovered then dl:AddRectFilled(pos, V2(pos.x + size, pos.y + size), U32(C.frameHov), 8) end
    local c = U32(hovered and C.text or C.textDim)
    local pad = size * 0.34
    dl:AddLine(V2(pos.x + pad, pos.y + pad), V2(pos.x + size - pad, pos.y + size - pad), c, 1.6)
    dl:AddLine(V2(pos.x + size - pad, pos.y + pad), V2(pos.x + pad, pos.y + size - pad), c, 1.6)
    return clicked
end

-- ================= МЕНЮ =================
local WIN_W, WIN_H = 500, 640

local function drawMenu()
    local resX, resY = getScreenResolution()
    imgui.SetNextWindowPos(V2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
    imgui.SetNextWindowSize(V2(WIN_W, WIN_H), imgui.Cond.Always)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V2(0, 0))
    imgui.Begin("##RadiusLavkiMenu", menuOpen, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
    imgui.PopStyleVar()

    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()

    -- заголовок
    local lx, ly = wp.x + 22, wp.y + 22
    dl:AddRectFilled(V2(lx, ly), V2(lx + 40, ly + 40), U32(C.accent), 11)
    withFont(fonts.bold, function()
        local ts = imgui.CalcTextSize("RL")
        dl:AddText(V2(lx + 20 - ts.x / 2, ly + 20 - ts.y / 2), U32(WHITE), "RL")
    end)
    imgui.SetCursorPos(V2(74, 18))
    withFont(fonts.title, function() imgui.Text("RadiusLavki") end)
    imgui.SetCursorPos(V2(74, 46))
    imgui.TextColored(C.textDim, u8"Где можно поставить лавку")
    if CloseButton("##close", V2(wp.x + WIN_W - 50, wp.y + 20), 30) then menuOpen[0] = false end

    imgui.SetCursorPos(V2(22, 84))
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0, 0, 0, 0))
    imgui.BeginChild("##content", V2(WIN_W - 44, WIN_H - 84 - 20), false)

    BeginCard("##c_main")
    if Toggle("##t_active", u8"Показ места под лавку", u8"/rlavka или ALT + 3", active) then setActive(not active) end
    EndCard("##c_main")

    BeginCard("##c_hints", u8"Подсказки")
    if Toggle("##t_arrow", u8"Стрелка к свободному месту", u8"Когда стоишь там, где ставить нельзя", v.arrow) then markDirty() end
    if Toggle("##t_sound", u8"Звук на свободном месте", u8"Короткий сигнал, когда кружок стал синим", v.sound) then markDirty() end
    if Toggle("##t_auto", u8"Выключать после установки", u8"Когда рядом с тобой появится новая лавка", v.autoOff) then markDirty() end
    if Toggle("##t_hotkey", u8"Горячая клавиша ALT + 3", u8"Включать и выключать показ без команды", v.hotkey) then markDirty() end
    EndCard("##c_hints")

    BeginCard("##c_sizes", u8"Размеры")
    Slider("##radius", u8"Минимум до чужой лавки", v.radius, 1.0, 15.0, u8"%.1f м")
    Slider("##area", u8"Показывать вокруг тебя", v.area, 5.0, 25.0, u8"%.0f м")
    Slider("##cell", u8"Точность заливки", v.cell, 0.4, 1.5, u8"%.1f м")
    FieldLabel(u8"Меньше значение = точнее края у чужих лавок, но ниже FPS.")
    EndCard("##c_sizes")

    BeginCard("##c_colors", u8"Цвета")
    ColorRow(u8"Свободное место", "##col_fill", v.fillCol)
    ColorRow(u8"Стрелка", "##col_arrow", v.arrCol)
    EndCard("##c_colors")

    BeginCard("##c_update", u8"Обновления")
    if Toggle("##t_upd", u8"Проверять при запуске", u8"Сам скачает новую версию с GitHub", v.autoUpd) then markDirty() end
    FieldLabel(u8("Версия " .. thisScript().version .. (update.text ~= '' and (". " .. update.text) or "")))
    imgui.Dummy(V2(0, 2))
    if StyledButton(update.busy and u8"Проверяю..." or u8"Проверить сейчас", V2(-1, 32)) then checkUpdate(true) end
    EndCard("##c_update")

    if StyledButton(u8"Сбросить все настройки", V2(-1, 36), 'danger') then resetAll() end

    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.End()
end

-- ================= КАДРЫ =================
imgui.OnFrame(function() return active and not isPauseMenuActive() end, function(player)
    player.HideCursor = true
    if not styleApplied then applyCustomStyle(); styleApplied = true end
    drawOverlay()
end)

imgui.OnFrame(function() return menuOpen[0] end, function()
    if not styleApplied then applyCustomStyle(); styleApplied = true end
    drawMenu()
end)

-- ================= MAIN =================
function main()
    while not isSampAvailable() do wait(0) end

    sampRegisterChatCommand('rlavka', function(arg)
        arg = (arg or ""):lower()
        if arg == "menu" or arg == "m" or arg == "меню" then
            menuOpen[0] = not menuOpen[0]
        else
            setActive(not active)
        end
    end)
    sampRegisterChatCommand('rlmenu', function() menuOpen[0] = not menuOpen[0] end)
    sampRegisterChatCommand('rlupdate', function() checkUpdate(true) end)

    if v.autoUpd[0] then checkUpdate(false) end

    local lastRefresh = -1
    while true do
        wait(0)

        if v.hotkey[0] and isKeyDown(vkeys.VK_MENU) and isKeyJustPressed(vkeys.VK_3)
            and not sampIsChatInputActive() and not sampIsDialogActive() then
            setActive(not active)
        end

        if active and os.clock() - lastRefresh > 0.33 then
            lastRefresh = os.clock()
            refreshStalls()
        end

        if dirtySince and os.clock() - dirtySince > 1.0 then
            dirtySince = nil
            inicfg.save(cfg, CFG_FILE)
        end
    end
end
