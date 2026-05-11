-- Roblox Studio plugin: Asset Reuploader (animations + sounds, live progress).
-- Install:
--   * Drop this file into your Plugins folder (Plugins tab > "Plugins Folder"),
--   * OR paste into a Script in Studio and right-click > "Save as Local Plugin..."

local plugin = plugin or getfenv().plugin
if typeof(plugin) ~= "Instance" or not plugin:IsA("Plugin") then
    error("Asset Reuploader must be run as a Studio plugin (plugin:CreateToolbar context).")
end

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local TweenService = game:GetService("TweenService")

----------------------------------------------------------------------
-- Constants & persisted settings
----------------------------------------------------------------------

local KEY_SERVER_BASE = "AssetReuploader_ServerBase_v2"
local KEY_MODE = "AssetReuploader_Mode_v1"
local DEFAULT_SERVER_BASE = "http://localhost:8080"
local POLL_INTERVAL = 0.4
local MAX_LOG_ENTRIES = 250
local TWEEN_FAST = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_BAR = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local MODE_BOTH = "both"
local MODE_ANIM = "anim"
local MODE_SOUND = "sound"
local VALID_MODES = { [MODE_BOTH] = true, [MODE_ANIM] = true, [MODE_SOUND] = true }

local PALETTE = {
    bg          = Color3.fromRGB(24, 24, 30),
    panel       = Color3.fromRGB(32, 32, 40),
    panel2      = Color3.fromRGB(40, 40, 50),
    panelHover  = Color3.fromRGB(50, 50, 62),
    text        = Color3.fromRGB(232, 232, 240),
    textDim     = Color3.fromRGB(170, 170, 190),
    textFaint   = Color3.fromRGB(120, 120, 140),
    border      = Color3.fromRGB(60, 60, 75),
    accent      = Color3.fromRGB(95, 175, 255),
    accentDeep  = Color3.fromRGB(55, 110, 175),
    success     = Color3.fromRGB(120, 220, 140),
    successDeep = Color3.fromRGB(60, 130, 90),
    warn        = Color3.fromRGB(220, 180, 100),
    danger      = Color3.fromRGB(230, 110, 110),
    dangerDeep  = Color3.fromRGB(110, 60, 65),
    barTrack    = Color3.fromRGB(40, 40, 52),
    logBg       = Color3.fromRGB(16, 16, 22),
}

local STATUS_META = {
    ok            = { color = PALETTE.success, glyph = "●" },
    owned         = { color = PALETTE.accent,  glyph = "○" },
    invalid       = { color = PALETTE.warn,    glyph = "?" },
    not_animation = { color = PALETTE.warn,    glyph = "—" },
    not_audio     = { color = PALETTE.warn,    glyph = "—" },
    no_games      = { color = PALETTE.warn,    glyph = "—" },
    fetch_failed  = { color = PALETTE.danger,  glyph = "×" },
    upload_failed = { color = PALETTE.danger,  glyph = "×" },
    info          = { color = PALETTE.textDim, glyph = "·" },
    error         = { color = PALETTE.danger,  glyph = "!" },
}

local serverBase = plugin:GetSetting(KEY_SERVER_BASE) or DEFAULT_SERVER_BASE

local savedMode = plugin:GetSetting(KEY_MODE)
local currentMode = (typeof(savedMode) == "string" and VALID_MODES[savedMode]) and savedMode or MODE_BOTH

local function endpoints()
    return {
        anim = serverBase .. "/reupload",
        sound = serverBase .. "/reupload_sound",
        progress = serverBase .. "/progress",
    }
end

local function urlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

----------------------------------------------------------------------
-- Toolbar / button / dock widget
----------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("Asset Reuploader")
local button = toolbar:CreateButton(
    "Reupload",
    "Open the Asset Reuploader panel",
    "rbxasset://textures/AnimationEditor/button_play_white.png"
)
button.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
    Enum.InitialDockState.Float,
    false, false,
    480, 460,
    400, 360
)

local widget = plugin:CreateDockWidgetPluginGui("AssetReuploaderWidget", widgetInfo)
widget.Title = "Asset Reuploader"
widget.Name = "AssetReuploaderWidget"

button.Click:Connect(function()
    widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
    button:SetActive(widget.Enabled)
end)

----------------------------------------------------------------------
-- Helpers for UI construction
----------------------------------------------------------------------

local function corner(parent, r) local c = Instance.new("UICorner", parent); c.CornerRadius = UDim.new(0, r or 6); return c end
local function stroke(parent, color, t) local s = Instance.new("UIStroke", parent); s.Color = color or PALETTE.border; s.Thickness = t or 1; s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; return s end
local function pad(parent, l, r, t, b)
    local p = Instance.new("UIPadding", parent)
    if l then p.PaddingLeft = UDim.new(0, l) end
    if r then p.PaddingRight = UDim.new(0, r) end
    if t then p.PaddingTop = UDim.new(0, t) end
    if b then p.PaddingBottom = UDim.new(0, b) end
    return p
end

local function attachHover(btn, baseColor, hoverColor, pressColor)
    btn.BackgroundColor3 = baseColor
    btn.AutoButtonColor = false
    local hoverActive = false
    local pressActive = false
    local function refresh()
        local target = baseColor
        if pressActive then target = pressColor or hoverColor or baseColor
        elseif hoverActive then target = hoverColor or baseColor end
        TweenService:Create(btn, TWEEN_FAST, { BackgroundColor3 = target }):Play()
    end
    btn.MouseEnter:Connect(function() hoverActive = true; refresh() end)
    btn.MouseLeave:Connect(function() hoverActive = false; pressActive = false; refresh() end)
    btn.MouseButton1Down:Connect(function() pressActive = true; refresh() end)
    btn.MouseButton1Up:Connect(function() pressActive = false; refresh() end)
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------

local root = Instance.new("Frame")
root.Size = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3 = PALETTE.bg
root.BorderSizePixel = 0
root.Parent = widget
pad(root, 12, 12, 12, 12)

local rootLayout = Instance.new("UIListLayout", root)
rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
rootLayout.Padding = UDim.new(0, 8)

-- Header: server URL row
local urlRow = Instance.new("Frame")
urlRow.Size = UDim2.new(1, 0, 0, 30)
urlRow.BackgroundTransparency = 1
urlRow.LayoutOrder = 10
urlRow.Parent = root

local urlLabel = Instance.new("TextLabel")
urlLabel.Size = UDim2.new(0, 60, 1, 0)
urlLabel.BackgroundTransparency = 1
urlLabel.TextXAlignment = Enum.TextXAlignment.Left
urlLabel.Text = "Server"
urlLabel.TextColor3 = PALETTE.textDim
urlLabel.Font = Enum.Font.GothamMedium
urlLabel.TextSize = 12
urlLabel.Parent = urlRow

local urlBox = Instance.new("TextBox")
urlBox.Size = UDim2.new(1, -65, 1, 0)
urlBox.Position = UDim2.new(0, 60, 0, 0)
urlBox.BackgroundColor3 = PALETTE.panel
urlBox.BorderSizePixel = 0
urlBox.TextXAlignment = Enum.TextXAlignment.Left
urlBox.Text = serverBase
urlBox.PlaceholderText = DEFAULT_SERVER_BASE
urlBox.PlaceholderColor3 = PALETTE.textFaint
urlBox.TextColor3 = PALETTE.text
urlBox.Font = Enum.Font.Code
urlBox.TextSize = 13
urlBox.ClearTextOnFocus = false
urlBox.Parent = urlRow
corner(urlBox, 5)
stroke(urlBox, PALETTE.border)
pad(urlBox, 8, 8)

urlBox.FocusLost:Connect(function()
    local v = urlBox.Text:gsub("%s+", ""):gsub("/+$", "")
    if v == "" then v = DEFAULT_SERVER_BASE end
    serverBase = v
    plugin:SetSetting(KEY_SERVER_BASE, v)
    urlBox.Text = v
end)

-- Mode selector row (Both / Animations only / Sounds only)
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.new(1, 0, 0, 28)
modeRow.BackgroundTransparency = 1
modeRow.LayoutOrder = 15
modeRow.Parent = root

local modeLabel = Instance.new("TextLabel")
modeLabel.Size = UDim2.new(0, 60, 1, 0)
modeLabel.BackgroundTransparency = 1
modeLabel.TextXAlignment = Enum.TextXAlignment.Left
modeLabel.Text = "Mode"
modeLabel.TextColor3 = PALETTE.textDim
modeLabel.Font = Enum.Font.GothamMedium
modeLabel.TextSize = 12
modeLabel.Parent = modeRow

local modeGroup = Instance.new("Frame")
modeGroup.Size = UDim2.new(1, -65, 1, 0)
modeGroup.Position = UDim2.new(0, 60, 0, 0)
modeGroup.BackgroundColor3 = PALETTE.panel
modeGroup.BorderSizePixel = 0
modeGroup.Parent = modeRow
corner(modeGroup, 5)
stroke(modeGroup, PALETTE.border)

local modeGroupLayout = Instance.new("UIListLayout", modeGroup)
modeGroupLayout.FillDirection = Enum.FillDirection.Horizontal
modeGroupLayout.SortOrder = Enum.SortOrder.LayoutOrder
modeGroupLayout.Padding = UDim.new(0, 0)

local modeButtons = {}

local function makeModeButton(label, modeValue, order)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1 / 3, 0, 1, 0)
    b.BorderSizePixel = 0
    b.BackgroundColor3 = PALETTE.panel
    b.AutoButtonColor = false
    b.Text = label
    b.TextColor3 = PALETTE.textDim
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.LayoutOrder = order
    b.Parent = modeGroup
    modeButtons[modeValue] = b
    return b
end

local modeBothBtn  = makeModeButton("Both",         MODE_BOTH,  1)
local modeAnimBtn  = makeModeButton("Animations",   MODE_ANIM,  2)
local modeSoundBtn = makeModeButton("Sounds",       MODE_SOUND, 3)

local function refreshModeButtons()
    for value, b in pairs(modeButtons) do
        local selected = (value == currentMode)
        local target = selected and PALETTE.accentDeep or PALETTE.panel
        TweenService:Create(b, TWEEN_FAST, {
            BackgroundColor3 = target,
            TextColor3 = selected and PALETTE.text or PALETTE.textDim,
        }):Play()
    end
end

local function setMode(newMode)
    if not VALID_MODES[newMode] then return end
    if newMode == currentMode then return end
    currentMode = newMode
    plugin:SetSetting(KEY_MODE, newMode)
    refreshModeButtons()
end

for value, b in pairs(modeButtons) do
    b.MouseEnter:Connect(function()
        if value ~= currentMode then
            TweenService:Create(b, TWEEN_FAST, { BackgroundColor3 = PALETTE.panelHover }):Play()
        end
    end)
    b.MouseLeave:Connect(function()
        if value ~= currentMode then
            TweenService:Create(b, TWEEN_FAST, { BackgroundColor3 = PALETTE.panel }):Play()
        end
    end)
    b.MouseButton1Click:Connect(function()
        setMode(value)
    end)
end

refreshModeButtons()

-- Action button row
local actionRow = Instance.new("Frame")
actionRow.Size = UDim2.new(1, 0, 0, 32)
actionRow.BackgroundTransparency = 1
actionRow.LayoutOrder = 20
actionRow.Parent = root

local function makeButton(parent, text, x, w, baseColor, hoverColor, pressColor)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 1, 0)
    b.Position = UDim2.new(0, x, 0, 0)
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = PALETTE.text
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 13
    b.Parent = parent
    corner(b, 5)
    attachHover(b, baseColor, hoverColor or baseColor, pressColor or hoverColor)
    return b
end

local startBtn = makeButton(actionRow, "▶  Start",   0,  108, PALETTE.successDeep, Color3.fromRGB(72, 150, 105), Color3.fromRGB(50, 110, 75))
local cancelBtn = makeButton(actionRow, "■  Cancel", 116, 92,  PALETTE.dangerDeep,  Color3.fromRGB(135, 70, 78),  Color3.fromRGB(95, 50, 56))
local clearBtn = makeButton(actionRow, "Clear log",  216, 90,  PALETTE.panel,       PALETTE.panelHover,           PALETTE.panel2)

-- Stats row (success / skipped / failed counters)
local statsRow = Instance.new("Frame")
statsRow.Size = UDim2.new(1, 0, 0, 28)
statsRow.BackgroundTransparency = 1
statsRow.LayoutOrder = 30
statsRow.Parent = root

local statsLayout = Instance.new("UIListLayout", statsRow)
statsLayout.FillDirection = Enum.FillDirection.Horizontal
statsLayout.Padding = UDim.new(0, 6)
statsLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function makeStat(parent, label, color, order)
    local pill = Instance.new("Frame")
    pill.Size = UDim2.new(0, 110, 1, 0)
    pill.BackgroundColor3 = PALETTE.panel
    pill.BorderSizePixel = 0
    pill.LayoutOrder = order
    pill.Parent = parent
    corner(pill, 5)
    pad(pill, 10, 10, 0, 0)

    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 3, 0.5, 0)
    accent.Position = UDim2.new(0, -10, 0.25, 0)
    accent.BackgroundColor3 = color
    accent.BorderSizePixel = 0
    accent.Parent = pill
    corner(accent, 2)

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(0.55, 0, 1, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
    nameLbl.Text = label
    nameLbl.TextColor3 = PALETTE.textDim
    nameLbl.Font = Enum.Font.GothamMedium
    nameLbl.TextSize = 11
    nameLbl.Parent = pill

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.new(0.45, 0, 1, 0)
    valLbl.Position = UDim2.new(0.55, 0, 0, 0)
    valLbl.BackgroundTransparency = 1
    valLbl.TextXAlignment = Enum.TextXAlignment.Right
    valLbl.Text = "0"
    valLbl.TextColor3 = color
    valLbl.Font = Enum.Font.GothamBold
    valLbl.TextSize = 14
    valLbl.Parent = pill

    return valLbl
end

local statSuccess = makeStat(statsRow, "OK",      PALETTE.success, 1)
local statSkipped = makeStat(statsRow, "Skipped", PALETTE.warn,    2)
local statFailed  = makeStat(statsRow, "Failed",  PALETTE.danger,  3)
local statOwned   = makeStat(statsRow, "Owned",   PALETTE.accent,  4)

-- Phase + count line
local phaseRow = Instance.new("Frame")
phaseRow.Size = UDim2.new(1, 0, 0, 18)
phaseRow.BackgroundTransparency = 1
phaseRow.LayoutOrder = 40
phaseRow.Parent = root

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Size = UDim2.new(0.7, 0, 1, 0)
phaseLabel.BackgroundTransparency = 1
phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
phaseLabel.Text = "Idle"
phaseLabel.TextColor3 = PALETTE.textDim
phaseLabel.Font = Enum.Font.GothamMedium
phaseLabel.TextSize = 13
phaseLabel.Parent = phaseRow

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(0.3, 0, 1, 0)
countLabel.Position = UDim2.new(0.7, 0, 0, 0)
countLabel.BackgroundTransparency = 1
countLabel.TextXAlignment = Enum.TextXAlignment.Right
countLabel.Text = "0 / 0"
countLabel.TextColor3 = PALETTE.text
countLabel.Font = Enum.Font.GothamBold
countLabel.TextSize = 13
countLabel.Parent = phaseRow

-- Progress bar
local barBg = Instance.new("Frame")
barBg.Size = UDim2.new(1, 0, 0, 8)
barBg.BackgroundColor3 = PALETTE.barTrack
barBg.BorderSizePixel = 0
barBg.LayoutOrder = 50
barBg.Parent = root
corner(barBg, 4)

local bar = Instance.new("Frame")
bar.Size = UDim2.new(0, 0, 1, 0)
bar.BackgroundColor3 = PALETTE.success
bar.BorderSizePixel = 0
bar.Parent = barBg
corner(bar, 4)

local barGloss = Instance.new("UIGradient", bar)
barGloss.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,    Color3.fromRGB(140, 230, 160)),
    ColorSequenceKeypoint.new(1,    Color3.fromRGB(70,  180, 110)),
})
barGloss.Rotation = 90

-- Latest replacement line
local latestLabel = Instance.new("TextLabel")
latestLabel.Size = UDim2.new(1, 0, 0, 16)
latestLabel.BackgroundTransparency = 1
latestLabel.TextXAlignment = Enum.TextXAlignment.Left
latestLabel.Text = "Latest: —"
latestLabel.TextColor3 = PALETTE.textDim
latestLabel.Font = Enum.Font.Code
latestLabel.TextSize = 11
latestLabel.TextTruncate = Enum.TextTruncate.AtEnd
latestLabel.LayoutOrder = 60
latestLabel.Parent = root

-- Log
local log = Instance.new("ScrollingFrame")
log.Size = UDim2.new(1, 0, 1, -246)
log.BackgroundColor3 = PALETTE.logBg
log.BorderSizePixel = 0
log.CanvasSize = UDim2.new(0, 0, 0, 0)
log.AutomaticCanvasSize = Enum.AutomaticSize.Y
log.ScrollBarThickness = 4
log.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
log.LayoutOrder = 70
log.Parent = root
corner(log, 5)
stroke(log, PALETTE.border)

local logLayout = Instance.new("UIListLayout", log)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding = UDim.new(0, 1)
pad(log, 8, 8, 6, 6)

----------------------------------------------------------------------
-- Stat / progress / log API
----------------------------------------------------------------------

local stats = { ok = 0, skipped = 0, failed = 0, owned = 0 }
local progressTarget = { c = 0, t = 0 }
local logEntries = 0

local function refreshStats()
    statSuccess.Text = tostring(stats.ok)
    statSkipped.Text = tostring(stats.skipped)
    statFailed.Text  = tostring(stats.failed)
    statOwned.Text   = tostring(stats.owned)
end

local function bumpStat(status)
    if status == "ok" then stats.ok = stats.ok + 1
    elseif status == "owned" then stats.owned = stats.owned + 1
    elseif status == "fetch_failed" or status == "upload_failed" or status == "error" then stats.failed = stats.failed + 1
    elseif status == "invalid" or status == "not_animation" or status == "not_audio" or status == "no_games" then stats.skipped = stats.skipped + 1
    end
    refreshStats()
end

local function resetStats()
    stats = { ok = 0, skipped = 0, failed = 0, owned = 0 }
    refreshStats()
end

local function setPhase(text, color)
    phaseLabel.Text = text
    phaseLabel.TextColor3 = color or PALETTE.textDim
end

local function setLatest(text, color)
    latestLabel.Text = "Latest: " .. (text or "—")
    latestLabel.TextColor3 = color or PALETTE.textDim
end

local function setCount(c, t)
    progressTarget.c = c
    progressTarget.t = t
    countLabel.Text = string.format("%d / %d", c, t)
    local frac = (t > 0) and math.clamp(c / t, 0, 1) or 0
    TweenService:Create(bar, TWEEN_BAR, { Size = UDim2.new(frac, 0, 1, 0) }):Play()
end

local function setBarColor(barColor, gradTop, gradBottom)
    TweenService:Create(bar, TWEEN_FAST, { BackgroundColor3 = barColor }):Play()
    barGloss.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, gradTop or barColor),
        ColorSequenceKeypoint.new(1, gradBottom or barColor),
    })
end

local function logEntry(text, status)
    logEntries = logEntries + 1
    local meta = STATUS_META[status] or STATUS_META.info

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 16)
    row.BackgroundTransparency = 1
    row.LayoutOrder = logEntries
    row.Parent = log

    local glyph = Instance.new("TextLabel")
    glyph.Size = UDim2.new(0, 12, 1, 0)
    glyph.BackgroundTransparency = 1
    glyph.Text = meta.glyph
    glyph.TextColor3 = meta.color
    glyph.Font = Enum.Font.GothamBold
    glyph.TextSize = 12
    glyph.TextXAlignment = Enum.TextXAlignment.Left
    glyph.Parent = row

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, -16, 1, 0)
    body.Position = UDim2.new(0, 16, 0, 0)
    body.BackgroundTransparency = 1
    body.Text = text
    body.TextColor3 = meta.color
    body.Font = Enum.Font.Code
    body.TextSize = 11
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextTruncate = Enum.TextTruncate.AtEnd
    body.Parent = row

    -- fade in
    body.TextTransparency = 1
    glyph.TextTransparency = 1
    TweenService:Create(body,  TWEEN_FAST, { TextTransparency = 0 }):Play()
    TweenService:Create(glyph, TWEEN_FAST, { TextTransparency = 0 }):Play()

    if logEntries > MAX_LOG_ENTRIES then
        local kids = {}
        for _, c in ipairs(log:GetChildren()) do
            if c:IsA("Frame") then table.insert(kids, c) end
        end
        table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
        for i = 1, #kids - MAX_LOG_ENTRIES do kids[i]:Destroy() end
    end
    log.CanvasPosition = Vector2.new(0, math.huge)
end

local function clearLog()
    for _, c in ipairs(log:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    logEntries = 0
end

clearBtn.MouseButton1Click:Connect(function()
    clearLog()
end)

----------------------------------------------------------------------
-- Asset extraction + indexing
----------------------------------------------------------------------

local function extractAnimationData()
    local unique = {}
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Animation") then
            local id = d.AnimationId:match("%d+")
            if id then unique[id] = d.Name end
        end
    end
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
            local src; pcall(function() src = d.Source end)
            if src then
                for id in src:gmatch("rbxassetid://(%d+)") do
                    if not unique[id] then unique[id] = d.Name end
                end
            end
        end
    end
    local out = {}
    for id, name in pairs(unique) do table.insert(out, { id = id, name = name }) end
    return out
end

local function extractSoundData()
    local unique = {}
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Sound") then
            local id = d.SoundId:match("%d+")
            if id then unique[id] = d.Name end
        end
    end
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
            local src; pcall(function() src = d.Source end)
            if src then
                for id in src:gmatch("rbxassetid://(%d+)") do
                    if not unique[id] then unique[id] = d.Name end
                end
            end
        end
    end
    local out = {}
    for id, name in pairs(unique) do table.insert(out, { id = id, name = name }) end
    return out
end

local function indexAssetReferences()
    local index = {}
    local function ensure(id)
        if not index[id] then index[id] = { animations = {}, sounds = {} } end
        return index[id]
    end
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Animation") then
            local id = d.AnimationId:match("%d+")
            if id then table.insert(ensure(id).animations, d) end
        elseif d:IsA("Sound") then
            local id = d.SoundId:match("%d+")
            if id then table.insert(ensure(id).sounds, d) end
        end
    end
    return index
end

local function applyLiveReplacement(assetIndex, oldId, newId)
    local entry = assetIndex[oldId]
    local count = 0
    if entry then
        for _, a in ipairs(entry.animations) do
            local ok = pcall(function() a.AnimationId = "rbxassetid://" .. newId end)
            if ok then count = count + 1 end
        end
        for _, s in ipairs(entry.sounds) do
            local ok = pcall(function() s.SoundId = "rbxassetid://" .. newId end)
            if ok then count = count + 1 end
        end
    end
    return count
end

local function replaceAssetIdsInScripts(idMap)
    local replaced = 0
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
            local ok, src = pcall(function() return d.Source end)
            if ok and src then
                local modified = false
                local newSrc = src:gsub("rbxassetid://(%d+)", function(oldId)
                    local newId = idMap[oldId]
                    if newId then
                        modified = true
                        return "rbxassetid://" .. newId
                    end
                    return "rbxassetid://" .. oldId
                end)
                if modified then
                    pcall(function() d.Source = newSrc end)
                    replaced = replaced + 1
                end
            end
        end
    end
    return replaced
end

----------------------------------------------------------------------
-- HTTP helpers
----------------------------------------------------------------------

local function postJSON(url, body)
    local ok, response = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(body),
        })
    end)
    if not ok then return nil, tostring(response) end
    if not response.Success then
        return nil, ("HTTP %d %s — %s"):format(response.StatusCode or 0, response.StatusMessage or "?", response.Body or "")
    end
    local decoded
    local okDecode, err = pcall(function() decoded = HttpService:JSONDecode(response.Body) end)
    if not okDecode then return nil, "decode error: " .. tostring(err) end
    return decoded, nil
end

local function getJSON(url)
    local ok, response = pcall(function()
        return HttpService:RequestAsync({ Url = url, Method = "GET" })
    end)
    if not ok then return nil, tostring(response) end
    if not response.Success then
        return nil, ("HTTP %d %s — %s"):format(response.StatusCode or 0, response.StatusMessage or "?", response.Body or "")
    end
    local decoded
    local okDecode, err = pcall(function() decoded = HttpService:JSONDecode(response.Body) end)
    if not okDecode then return nil, "decode error: " .. tostring(err) end
    return decoded, nil
end

----------------------------------------------------------------------
-- Job runner
----------------------------------------------------------------------

local activeRun = { cancelled = false, running = false }

local function isCancelled() return activeRun.cancelled end

cancelBtn.MouseButton1Click:Connect(function()
    if activeRun.running then
        activeRun.cancelled = true
        logEntry("Cancellation requested", "info")
    end
end)

local function runJob(kind, serverUrl, payloadKey, dataList, assetIndex)
    if #dataList == 0 then
        logEntry(("No %s candidates"):format(kind), "info")
        return {}
    end

    setPhase(("Starting %s upload (%d items)…"):format(kind, #dataList), PALETTE.accent)
    setCount(0, #dataList)
    setBarColor(PALETTE.success, Color3.fromRGB(140, 230, 160), Color3.fromRGB(70, 180, 110))

    local startResp, err = postJSON(serverUrl .. "?async=1", { [payloadKey] = dataList })
    if not startResp then
        logEntry(("Failed to start %s job: %s"):format(kind, err), "error")
        return nil
    end

    local jobId = startResp.jobId
    local total = startResp.total or #dataList
    if not jobId then
        logEntry(("Server did not return jobId for %s"):format(kind), "error")
        return nil
    end

    setPhase(("Uploading %s (live)…"):format(kind), PALETTE.accent)
    setCount(0, total)

    local newIds = {}
    local consecutiveErrors = 0
    local kindInitial = kind:sub(1, 1):upper()

    while true do
        if isCancelled() then
            logEntry(("[%s] Cancelled"):format(kindInitial), "error")
            return newIds
        end
        task.wait(POLL_INTERVAL)

        local prog, perr = getJSON(endpoints().progress .. "?jobId=" .. urlEncode(jobId))
        if not prog then
            consecutiveErrors = consecutiveErrors + 1
            logEntry(("Poll error: %s"):format(perr), "error")
            if consecutiveErrors >= 5 then
                logEntry(("Aborting %s after %d poll errors"):format(kind, consecutiveErrors), "error")
                return nil
            end
        else
            consecutiveErrors = 0
            for _, item in ipairs(prog.delta or {}) do
                local oldId = item.oldId
                local newId = item.newId
                local name  = item.name or ""
                local status = item.status or "ok"

                bumpStat(status)
                if newId then
                    newIds[oldId] = newId
                    local replaced = applyLiveReplacement(assetIndex, oldId, newId)
                    logEntry(("[%s] %s → %s  (%s, %d refs)"):format(kindInitial, oldId, newId, name, replaced), status)
                    setLatest(("%s → %s"):format(oldId, newId), STATUS_META[status] and STATUS_META[status].color)
                else
                    logEntry(("[%s] %s — %s (%s)"):format(kindInitial, oldId, status, name), status)
                end
            end

            setCount(prog.completed or 0, prog.total or total)

            if prog.done then
                for _, e in ipairs(prog.errors or {}) do
                    logEntry(("Server error: %s"):format(tostring(e)), "error")
                end
                break
            end
        end
    end

    return newIds
end

----------------------------------------------------------------------
-- Main run
----------------------------------------------------------------------

local function setStartActive(active)
    if active then
        startBtn.Text = "▶  Start"
        TweenService:Create(startBtn, TWEEN_FAST, { BackgroundColor3 = PALETTE.successDeep }):Play()
        startBtn.Active = true
    else
        startBtn.Text = "⏳  Working"
        TweenService:Create(startBtn, TWEEN_FAST, { BackgroundColor3 = Color3.fromRGB(60, 60, 70) }):Play()
        startBtn.Active = false
    end
end

local function modeLabelText(mode)
    if mode == MODE_ANIM then return "animations only"
    elseif mode == MODE_SOUND then return "sounds only"
    else return "animations + sounds" end
end

local function runReupload()
    if activeRun.running then
        logEntry("Already running", "info")
        return
    end
    activeRun = { cancelled = false, running = true }
    setStartActive(false)

    pcall(function() ChangeHistoryService:SetWaypoint("AssetReuploader: Start") end)

    clearLog()
    resetStats()
    setPhase("Indexing instances…", PALETTE.textDim)
    setCount(0, 0)
    setLatest(nil)

    local mode = currentMode
    logEntry(("Mode: %s"):format(modeLabelText(mode)), "info")

    local assetIndex = indexAssetReferences()

    local doAnim = (mode == MODE_BOTH or mode == MODE_ANIM)
    local doSound = (mode == MODE_BOTH or mode == MODE_SOUND)

    local animationData = {}
    if doAnim then
        logEntry("Extracting animations…", "info")
        animationData = extractAnimationData()
        logEntry(("Found %d animation candidates"):format(#animationData), "info")
    else
        logEntry("Skipping animations (mode: sounds only)", "info")
    end

    local soundData = {}
    if doSound then
        logEntry("Extracting sounds…", "info")
        soundData = extractSoundData()
        logEntry(("Found %d sound candidates"):format(#soundData), "info")
    else
        logEntry("Skipping sounds (mode: animations only)", "info")
    end

    local urls = endpoints()
    local animResult = {}
    if doAnim and not isCancelled() then
        animResult = runJob("animation", urls.anim, "animationData", animationData, assetIndex) or {}
    end

    local soundResult = {}
    if doSound and not isCancelled() then
        soundResult = runJob("sound", urls.sound, "soundData", soundData, assetIndex) or {}
    end

    setPhase("Replacing IDs in scripts…", PALETTE.accent)
    local combined = {}
    for k, v in pairs(animResult) do combined[k] = v end
    for k, v in pairs(soundResult) do combined[k] = v end
    local scriptCount = replaceAssetIdsInScripts(combined)
    logEntry(("Scripts updated: %d"):format(scriptCount), "ok")

    local function size(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end
    if activeRun.cancelled then
        setPhase("Cancelled", PALETTE.danger)
        setBarColor(PALETTE.danger, Color3.fromRGB(240, 130, 130), Color3.fromRGB(180, 70, 80))
    else
        setPhase("Done", PALETTE.success)
    end
    logEntry(("Done — animations: %d, sounds: %d, scripts: %d"):format(size(animResult), size(soundResult), scriptCount), "ok")

    pcall(function() ChangeHistoryService:SetWaypoint("AssetReuploader: Done") end)

    activeRun.running = false
    setStartActive(true)
end

startBtn.MouseButton1Click:Connect(function()
    if not startBtn.Active then return end
    task.spawn(function()
        local ok, err = pcall(runReupload)
        if not ok then
            logEntry("FATAL: " .. tostring(err), "error")
            activeRun.running = false
            setStartActive(true)
        end
    end)
end)

refreshStats()

plugin.Unloading:Connect(function()
    activeRun.cancelled = true
    if widget then widget:Destroy() end
end)
