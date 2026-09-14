--[[
    GCDDot
    A tiny, movable, resizable dot whose fill is a genuine circular pie-wipe
    (not the square-bounded Cooldown-widget swipe - see note below) tracking
    your GCD clockwise from 12 o'clock, then pulses a single soft/feathered
    glow the instant you're actually free to act again (see the cast/channel
    note below). A thin outer ring around the dot separately tracks your
    melee swing timer the same way. Hidden automatically out of combat
    (while locked) so it doesn't clutter your screen when it isn't relevant.

    GCD detection: spell ID 61304 is a hidden dummy spell Blizzard uses
    internally that is ALWAYS on cooldown for exactly the GCD's duration
    whenever you trigger the GCD, regardless of class/spec. Polling
    GetSpellCooldown(61304) is the standard, addon-safe way to track the GCD.

    Circular fill: the native Cooldown widget (used for action button
    cooldowns) can't be recolored or reshaped on real 3.3.5 - that
    customization (SetSwipeColor/SetSwipeTexture) wasn't added until
    Cataclysm's 4.0, so its default dark swipe always fills its full SQUARE
    footprint, clashing against a circular design. Instead, media\piewheel.tga
    (shipped with this addon) is a hand-generated 64-frame sprite sheet of
    genuine anti-aliased circular pie-fill frames (0% to 100%, clockwise from
    12 o'clock); each poll tick we just pick the right frame via SetTexCoord
    based on elapsed-time fraction. No Cooldown widget involved at all for
    either fill.

    Flash timing vs casting: if the GCD finishes while you're still in the
    middle of a cast-time or channeled spell (e.g. a 3s Fireball on a 1.5s
    GCD), flashing right when the GCD ends would be misleading - you can't
    actually act yet. So the flash is held and fired instead the moment the
    cast/channel completes.

    Swing ring: a larger, dimmer copy of the same soft circle sits BEHIND
    the core dot at a lower frame level, so the core dot visually "punches
    a hole" in its middle - what's left showing around the edge reads as a
    thin ring. Its own pie-wipe fill, timed off UnitAttackSpeed() and reset
    whenever a melee swing (SWING_DAMAGE/SWING_MISSED) lands, fills up
    between one auto-attack swing and the next. NOTE: this only tracks your
    main-hand pace - for dual-wielders an off-hand swing will still reset
    it, which isn't perfectly accurate for the off-hand's own timing, but
    keeps things simple for now.

    Slash commands (either /gcddot or /gcd):
        /gcd unlock          - unlock the dot so you can drag it, shows a
                                border and always stays visible while unlocked
        /gcd lock            - lock it back down
        /gcd size <n>        - set the core dot's diameter in pixels (4-64)
        /gcd color <r g b>   - set the core/GCD color, each 0-1
        /gcd classcolor      - toggle using your class's official color instead
                                (from Blizzard's own RAID_CLASS_COLORS table)
        /gcd swing           - toggle the swing timer ring (on by default)
        /gcd swingcolor <r g b> - set the swing ring's color, each 0-1
        /gcd combat          - toggle hiding the dot outside of combat (on by default)
        /gcd reset           - reset everything to defaults
        /gcd test            - fire a preview flash without needing a GCD
--]]

-- NOTE: 3.3.5a does NOT pass (addonName, addonTable) into the addon file's
-- vararg the way modern clients do (that was added in patch 5.1) - so we
-- hardcode the name here and compare it to the ADDON_LOADED event payload.
local ADDON_NAME = "GCDDot"
local GCD_SPELL_ID = 61304
local RING_SCALE = 1.55 -- swing ring's diameter relative to the core dot's
                         -- size (back up from the earlier reduced value -
                         -- that was only needed to hide the old square swipe)

local PIE_TEXTURE = "Interface\\AddOns\\GCDDot\\media\\piewheel.tga"
local PIE_FRAMES = 64
local PIE_GRID = 8 -- 8x8 grid of frames in the atlas

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
    showSwing = true,
    swingR = 1,
    swingG = 1,
    swingB = 1,
    useClassColor = false,
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

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40d9ffGCDDot|r: " .. msg)
end

--------------------------------------------------------------------------
-- Pie-fill helper
--------------------------------------------------------------------------
-- Picks the correct cell out of the piewheel.tga atlas for a given
-- progress fraction (0 = empty, 1 = full circle), via plain SetTexCoord -
-- no Cooldown widget, no rotation API, nothing that varies by client build.

local function SetPieFraction(tex, frac)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local idx = math.floor(frac * (PIE_FRAMES - 1) + 0.5)
    local col = idx % PIE_GRID
    local row = math.floor(idx / PIE_GRID)
    local u0, u1 = col / PIE_GRID, (col + 1) / PIE_GRID
    local v0, v1 = row / PIE_GRID, (row + 1) / PIE_GRID
    tex:SetTexCoord(u0, u1, v0, v1)
end

--------------------------------------------------------------------------
-- Frame + visuals
--------------------------------------------------------------------------
-- Layer stack, back to front:
--   ringLayer  (lower frame level) - swingBase (dim marker) + swingPie (fill)
--   dotLayer   (higher frame level) - core (dim marker) + cdPie (fill) + glow
-- The dim markers reuse the soft alpha-gradient texture so they're always
-- feathered; the *Pie textures use the generated circular atlas above them.

local SOFT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local frame = CreateFrame("Frame", "GCDDotFrame", UIParent)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")

local baseLevel = frame:GetFrameLevel()

-- ring layer (swing timer) - deliberately BELOW the dot layer
local ringLayer = CreateFrame("Frame", nil, frame)
ringLayer:SetAllPoints(frame)
ringLayer:SetFrameLevel(baseLevel + 1)

local swingBase = ringLayer:CreateTexture(nil, "ARTWORK")
swingBase:SetTexture(SOFT_TEXTURE)
swingBase:SetPoint("CENTER", frame, "CENTER")

local swingPie = ringLayer:CreateTexture(nil, "OVERLAY")
swingPie:SetTexture(PIE_TEXTURE)
swingPie:SetPoint("CENTER", frame, "CENTER")
SetPieFraction(swingPie, 0)

-- dot layer (core + GCD fill + flash) - explicitly ABOVE the ring layer
local dotLayer = CreateFrame("Frame", nil, frame)
dotLayer:SetAllPoints(frame)
dotLayer:SetFrameLevel(baseLevel + 3)

local core = dotLayer:CreateTexture(nil, "ARTWORK")
core:SetTexture(SOFT_TEXTURE)
core:SetPoint("CENTER", frame, "CENTER")

local cdPie = dotLayer:CreateTexture(nil, "OVERLAY", nil, 0)
cdPie:SetTexture(PIE_TEXTURE)
cdPie:SetPoint("CENTER", frame, "CENTER")
SetPieFraction(cdPie, 0)

local glow = dotLayer:CreateTexture(nil, "OVERLAY", nil, 1) -- sublevel 1: always above cdPie
glow:SetTexture(SOFT_TEXTURE)
glow:SetBlendMode("ADD")
glow:SetAlpha(0)
glow:SetPoint("CENTER", frame, "CENTER")

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

    local ringSize = size * RING_SCALE
    frame:SetSize(ringSize, ringSize) -- overall footprint = outer ring's extent
    core:SetSize(size, size)
    cdPie:SetSize(size, size)
    glow:SetSize(size * 2.6, size * 2.6)
    swingBase:SetSize(ringSize, ringSize)
    swingPie:SetSize(ringSize, ringSize)
end

local function ApplyColorRaw(r, g, b)
    core:SetVertexColor(r, g, b, 0.35) -- dim always-visible marker
    cdPie:SetVertexColor(r, g, b, 0.95) -- brighter growing fill
    glow:SetVertexColor(r, g, b, 1)
end

local function ApplyColor(r, g, b)
    db.r, db.g, db.b = r, g, b
    db.useClassColor = false -- an explicit manual color opts back out of class-color mode
    ApplyColorRaw(r, g, b)
end

-- RAID_CLASS_COLORS is a long-standing Blizzard FrameXML global (present
-- since Vanilla, used throughout the default UI) mapping the English class
-- token to its official {r,g,b} - exactly the palette wowwiki documents,
-- straight from the client, no hardcoded table to keep in sync ourselves.
local function GetClassColor()
    local _, classToken = UnitClass("player")
    local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c then
        return c.r, c.g, c.b
    end
    return nil
end

local function ApplyClassColor()
    local r, g, b = GetClassColor()
    if not r then
        Print("couldn't determine your class color - leaving the current color as-is.")
        return
    end
    db.useClassColor = true
    ApplyColorRaw(r, g, b) -- deliberately does NOT touch db.r/g/b, so your last
                            -- manual color is preserved underneath if you turn
                            -- class-color mode back off later
end

local function ApplySwingColor(r, g, b)
    db.swingR, db.swingG, db.swingB = r, g, b
    swingBase:SetVertexColor(r, g, b, 0.3)
    swingPie:SetVertexColor(r, g, b, 0.9)
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
-- Cast/channel tracking (delay the flash until you can actually act)
--------------------------------------------------------------------------
-- 3.3.5a note: the no-arg CastingInfo()/ChannelInfo() globals do NOT exist
-- on original WotLK (they were only added in the 2019 Classic relaunch) -
-- the correct era-appropriate calls are UnitCastingInfo("player") /
-- UnitChannelInfo("player"). Their pre-Legion return signature also still
-- includes a "nameSubtext" field (removed in patch 8.0.1) that shifts
-- startTime/endTime to the 5th/6th return values - important to get right
-- or you silently read the wrong field instead of erroring.

local castEndTime = nil -- set while a cast/channel is in progress that
                         -- outlasts the GCD; nil otherwise
local pendingFlash = false

local function RefreshCastEnd()
    local name, _, _, _, startTime, endTime = UnitCastingInfo("player")
    if name then
        castEndTime = endTime / 1000
        return
    end
    local cName, _, _, _, cStart, cEndTime = UnitChannelInfo("player")
    if cName then
        castEndTime = cEndTime / 1000
        return
    end
    castEndTime = nil
end

local castWatcher = CreateFrame("Frame")
castWatcher:RegisterEvent("UNIT_SPELLCAST_START")
castWatcher:RegisterEvent("UNIT_SPELLCAST_DELAYED")
castWatcher:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
castWatcher:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
castWatcher:RegisterEvent("UNIT_SPELLCAST_STOP")
castWatcher:RegisterEvent("UNIT_SPELLCAST_FAILED")
castWatcher:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
castWatcher:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
castWatcher:SetScript("OnEvent", function(self, event, unit)
    if unit ~= "player" then return end

    if event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_DELAYED"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        RefreshCastEnd()
    else
        -- STOP / FAILED / INTERRUPTED / CHANNEL_STOP: whatever was pending
        -- is over one way or another, so this is the moment you're free to
        -- act again - fire the held-back flash now if one was waiting.
        castEndTime = nil
        if pendingFlash then
            pendingFlash = false
            Flash()
        end
    end
end)

--------------------------------------------------------------------------
-- Swing timer (thin outer ring)
--------------------------------------------------------------------------
-- Detected the classic way: watch the combat log for a SWING_DAMAGE or
-- SWING_MISSED event whose source is you, then restart a timer for
-- UnitAttackSpeed("player")'s main-hand speed.
--
-- 3.3.5a note: COMBAT_LOG_EVENT_UNFILTERED's payload has genuinely varied
-- across patches/backports depending on whether the "hideCaster" field
-- (officially added in patch 4.1) is present, which shifts sourceGUID from
-- argument 3 to argument 4. Rather than hardcode one and risk silently
-- reading the wrong field on some servers, we just check both positions.

local hasSwung = false
local swingStart = nil
local swingDuration = nil

local function ApplySwingVisibility()
    if db.showSwing and hasSwung then
        ringLayer:Show()
    else
        ringLayer:Hide()
    end
end

local function ResetSwingRing()
    hasSwung = false
    swingStart, swingDuration = nil, nil
    SetPieFraction(swingPie, 0)
    ApplySwingVisibility()
end

local function StartSwingTimer()
    local mainSpeed = UnitAttackSpeed("player")
    if not mainSpeed or mainSpeed <= 0 then return end
    hasSwung = true
    swingStart, swingDuration = GetTime(), mainSpeed
    SetPieFraction(swingPie, 0)
    ApplySwingVisibility()
end

local swingWatcher = CreateFrame("Frame")
swingWatcher:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
swingWatcher:RegisterEvent("PLAYER_REGEN_ENABLED") -- leaving combat: reset for next time
swingWatcher:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_REGEN_ENABLED" then
        ResetSwingRing()
        return
    end

    local subevent = select(2, ...)
    if subevent ~= "SWING_DAMAGE" and subevent ~= "SWING_MISSED" then return end

    local a3, a4 = select(3, ...), select(4, ...)
    local playerGUID = UnitGUID("player")
    if a3 == playerGUID or a4 == playerGUID then
        if db.showSwing then
            StartSwingTimer()
        end
    end
end)

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

    -- swing ring fill
    if swingStart then
        local frac = (GetTime() - swingStart) / swingDuration
        SetPieFraction(swingPie, frac)
        if frac >= 1 then
            swingStart, swingDuration = nil, nil -- stays full until the next swing resets it
        end
    end

    local start, duration = GetSpellCooldown(GCD_SPELL_ID)
    local active = start and duration and duration > 0

    if active and start ~= lastStart then
        -- a new GCD just started - kick off the pie fill from scratch
        lastStart = start
    end

    if active then
        SetPieFraction(cdPie, (GetTime() - start) / duration)
    end

    if active and not gcdActive then
        gcdActive = true
    elseif gcdActive and not active then
        gcdActive = false
        SetPieFraction(cdPie, 1) -- make sure it lands on "full" exactly
        if castEndTime then
            -- still mid-cast/channel past the GCD - hold the flash until
            -- that finishes instead of firing while you still can't act
            pendingFlash = true
        else
            Flash()
        end
    end
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

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
    elseif cmd == "classcolor" then
        db.useClassColor = not db.useClassColor
        if db.useClassColor then
            ApplyClassColor()
            Print("using your class color.")
        else
            ApplyColorRaw(db.r, db.g, db.b)
            Print("class color off - back to your custom color.")
        end
    elseif cmd == "swing" then
        db.showSwing = not db.showSwing
        ApplySwingVisibility()
        Print("swing timer ring: " .. (db.showSwing and "ON" or "OFF"))
    elseif cmd == "swingcolor" then
        local r, g, b = rest:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            ApplySwingColor(r, g, b)
            Print("swing ring color updated.")
        else
            Print("usage: /gcd swingcolor <r> <g> <b>  (each 0-1)")
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
        ApplySwingColor(db.swingR, db.swingG, db.swingB)
        ResetSwingRing()
        ApplyLockState()
        Print("reset to defaults.")
    elseif cmd == "test" then
        Flash()
    else
        Print("commands: unlock, lock, size <n>, color <r g b>, classcolor, swing, swingcolor <r g b>, combat, reset, test")
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
    if db.useClassColor then
        ApplyClassColor() -- re-derive from THIS character's class, since the
                           -- saved color is account-wide and shared across alts
    else
        ApplyColorRaw(db.r, db.g, db.b)
    end
    ApplySwingColor(db.swingR, db.swingG, db.swingB)
    ApplySwingVisibility() -- ring stays hidden until the first swing lands
    ApplyLockState()

    self:UnregisterEvent("ADDON_LOADED")
end)
