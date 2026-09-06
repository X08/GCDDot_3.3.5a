--[[
    GCDDot
    A tiny, movable, resizable dot that clock-wipes clockwise in sync with
    your GCD, then pulses a single soft/feathered glow the instant it ends.
    Hidden automatically out of combat (while locked) so it doesn't clutter
    your screen when it isn't relevant.

    Detection trick: spell ID 61304 is a hidden dummy spell Blizzard uses
    internally that is ALWAYS on cooldown for exactly the GCD's duration
    whenever you trigger the GCD, regardless of class/spec. Polling
    GetSpellCooldown(61304) is the standard, addon-safe way to track the GCD.
    That start/duration is fed straight into a native Cooldown widget (the
    same clock-wipe used on action buttons), which does the clockwise fill
    for us.

    Slash commands (either /gcddot or /gcd):
        /gcd unlock          - unlock the dot so you can drag it, shows a
                                border and always stays visible while unlocked
        /gcd lock            - lock it back down
        /gcd size <n>        - set the core dot's diameter in pixels (4-64)
        /gcd color <r g b>   - set the color, each 0-1, e.g. /gcd color 1 0.3 0.1
        /gcd combat          - toggle hiding the dot outside of combat (on by default)
        /gcd reset           - reset position, size, color and combat setting to defaults
        /gcd test            - fire a preview flash without needing a GCD
--]]

-- NOTE: 3.3.5a does NOT pass (addonName, addonTable) into the addon file's
-- vararg the way modern clients do (that was added in patch 5.1) - so we
-- hardcode the name here and compare it to the ADDON_LOADED event payload.
local ADDON_NAME = "GCDDot"
local GCD_SPELL_ID = 61304

--------------------------------------------------------------------------
-- Defaults / saved variables
--------------------------------------------------------------------------

local defaults = {
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = -150,
    size = 14,
    r = 0.4,
    g = 0.85,
    b = 1.0,
    locked = true,
    hideOutOfCombat = true,
}

local db

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

--------------------------------------------------------------------------
-- Frame + visuals
--------------------------------------------------------------------------
-- Layer 1 ("core"): a small, always-visible marker so you can find/position
--   the dot. Uses a texture whose alpha channel is already a soft radial
--   gradient, so the edges are naturally feathered rather than a hard-edged
--   square/circle.
-- Layer 2 ("glow"): a larger copy of the same soft texture, additive blend,
--   alpha 0 at rest. This is what animates: a single quick fade-in then a
--   slower fade-out every time the GCD ends, giving the "flash of glow" look.

local SOFT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local frame = CreateFrame("Frame", "GCDDotFrame", UIParent)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")

local core = frame:CreateTexture(nil, "ARTWORK")
core:SetTexture(SOFT_TEXTURE)
core:SetAllPoints(frame)

local glow = frame:CreateTexture(nil, "OVERLAY")
glow:SetTexture(SOFT_TEXTURE)
glow:SetBlendMode("ADD")
glow:SetAlpha(0)
glow:SetPoint("CENTER", frame, "CENTER")

-- Layer 3 ("cd"): the native Blizzard "Cooldown" widget - the same clock-wipe
-- used on action buttons. Feeding it start/duration makes it sweep clockwise
-- from 12 o'clock, progressively uncovering the core dot as the GCD elapses,
-- so the dot reads as "filling up" in sync with the real cooldown, for free
-- and pixel-perfect, no manual pie-slice math needed.
local cd = CreateFrame("Cooldown", "GCDDotCooldown", frame)
cd:SetAllPoints(frame)
-- SetSwipeColor/SetSwipeTexture were added after 3.3.5 on some clients and
-- not others depending on private-server backport - guard them so a missing
-- method can't break the rest of the file the way SetFromAlpha did.
if cd.SetSwipeColor then
    cd:SetSwipeColor(0, 0, 0, 0.85)
end
if cd.SetDrawEdge then
    cd:SetDrawEdge(false)
end

-- unlocked-mode helper visuals (border + label), hidden while locked
local border = CreateFrame("Frame", nil, frame)
border:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
border:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 8,
})
border:SetBackdropBorderColor(1, 1, 1, 0.6)
border:Hide()

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("BOTTOM", frame, "TOP", 0, 6)
label:SetText("GCD Dot (drag me)")
label:Hide()

--------------------------------------------------------------------------
-- Sizing / coloring
--------------------------------------------------------------------------

local function ApplySize(size)
    size = math.max(4, math.min(64, size))
    db.size = size
    frame:SetSize(size, size)
    glow:SetSize(size * 2.6, size * 2.6)
end

local function ApplyColor(r, g, b)
    db.r, db.g, db.b = r, g, b
    core:SetVertexColor(r, g, b, 0.85)
    glow:SetVertexColor(r, g, b, 1)
end

local function ApplyPosition()
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function UpdateVisibility()
    if not db.locked then
        -- always visible while unlocked, so you can find/drag/size it
        frame:Show()
        return
    end
    local inCombat = InCombatLockdown and InCombatLockdown() or UnitAffectingCombat("player")
    if not db.hideOutOfCombat or inCombat then
        frame:Show()
    else
        frame:Hide()
    end
end

local function ApplyLockState()
    if db.locked then
        frame:EnableMouse(false)
        border:Hide()
        label:Hide()
    else
        frame:EnableMouse(true)
        border:Show()
        label:Show()
    end
    UpdateVisibility()
end

--------------------------------------------------------------------------
-- Dragging
--------------------------------------------------------------------------

frame:SetScript("OnDragStart", function(self)
    if not db.locked then
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

-- mouse wheel resize while unlocked, for quick adjustment without typing
frame:EnableMouseWheel(true)
frame:SetScript("OnMouseWheel", function(self, delta)
    if db.locked then return end
    ApplySize(db.size + delta)
end)

--------------------------------------------------------------------------
-- Combat visibility
--------------------------------------------------------------------------

frame:RegisterEvent("PLAYER_REGEN_DISABLED") -- entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- leaving combat
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()
    end
end)

--------------------------------------------------------------------------
-- Flash animation (single pulse of feathered glow)
--------------------------------------------------------------------------

local animGroup = glow:CreateAnimationGroup()

local fadeIn = animGroup:CreateAnimation("Alpha")
fadeIn:SetChange(1)      -- 3.3.5 Alpha animations use SetChange, not SetFromAlpha/SetToAlpha
fadeIn:SetDuration(0.07)
fadeIn:SetOrder(1)

local fadeOut = animGroup:CreateAnimation("Alpha")
fadeOut:SetChange(-1)
fadeOut:SetDuration(0.42)
fadeOut:SetOrder(2)

animGroup:SetScript("OnPlay", function()
    glow:SetAlpha(0) -- guarantee fadeIn starts from 0 regardless of prior state
end)

animGroup:SetScript("OnFinished", function()
    glow:SetAlpha(0)
end)

local function Flash()
    animGroup:Stop()
    glow:SetAlpha(0)
    animGroup:Play()
end

--------------------------------------------------------------------------
-- GCD polling
--------------------------------------------------------------------------

local gcdActive = false
local lastStart = 0
local poller = CreateFrame("Frame")
local elapsedAccum = 0
local combatPollAccum = 0
local POLL_INTERVAL = 0.02   -- 50x/sec is plenty to catch the GCD ending cleanly
local COMBAT_POLL_INTERVAL = 0.25 -- self-healing check in case the combat
                                   -- events don't fire reliably on some cores

poller:SetScript("OnUpdate", function(self, elapsed)
    combatPollAccum = combatPollAccum + elapsed
    if combatPollAccum >= COMBAT_POLL_INTERVAL then
        combatPollAccum = 0
        UpdateVisibility()
    end

    elapsedAccum = elapsedAccum + elapsed
    if elapsedAccum < POLL_INTERVAL then return end
    elapsedAccum = 0

    local start, duration = GetSpellCooldown(GCD_SPELL_ID)
    local active = start and duration and duration > 0

    if active and start ~= lastStart then
        -- a new GCD just started - kick off the clock-wipe fill from scratch
        cd:SetCooldown(start, duration)
        lastStart = start
    end

    if active and not gcdActive then
        gcdActive = true
    elseif gcdActive and not active then
        gcdActive = false
        Flash()
    end
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40d9ffGCDDot|r: " .. msg)
end

local function SlashHandler(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "unlock" then
        db.locked = false
        ApplyLockState()
        Print("unlocked - drag to move, mouse-wheel to resize. Type /gcd lock when done.")
    elseif cmd == "lock" then
        db.locked = true
        ApplyLockState()
        Print("locked.")
    elseif cmd == "size" then
        local n = tonumber(rest)
        if n then
            ApplySize(n)
            Print("size set to " .. db.size .. ".")
        else
            Print("usage: /gcd size <4-64>")
        end
    elseif cmd == "color" then
        local r, g, b = rest:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            ApplyColor(r, g, b)
            Print("color updated.")
        else
            Print("usage: /gcd color <r> <g> <b>  (each 0-1)")
        end
    elseif cmd == "combat" then
        db.hideOutOfCombat = not db.hideOutOfCombat
        UpdateVisibility()
        Print("hide out of combat: " .. (db.hideOutOfCombat and "ON" or "OFF"))
    elseif cmd == "reset" then
        for k, v in pairs(defaults) do db[k] = v end
        ApplyPosition()
        ApplySize(db.size)
        ApplyColor(db.r, db.g, db.b)
        ApplyLockState()
        Print("reset to defaults.")
    elseif cmd == "test" then
        Flash()
    else
        Print("commands: unlock, lock, size <n>, color <r g b>, combat, reset, test")
    end
end

SLASH_GCDDOT1 = "/gcddot"
SLASH_GCDDOT2 = "/gcd"
SlashCmdList["GCDDOT"] = SlashHandler

--------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------

local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(self, event, name)
    if name ~= ADDON_NAME then return end

    GCDDotDB = GCDDotDB or {}
    db = CopyDefaults(GCDDotDB, defaults)

    ApplyPosition()
    ApplySize(db.size)
    ApplyColor(db.r, db.g, db.b)
    ApplyLockState()

    self:UnregisterEvent("ADDON_LOADED")
end)
