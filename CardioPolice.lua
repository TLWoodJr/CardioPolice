-- Cardio Police: pops up a workout after each dungeon and after every hour
-- spent outside dungeons, cycling through a rotation of exercises.
--
-- Partner sync: both players run /cardio partner <name>. The rotation
-- position and rep counts stay in sync (newest change wins, catching up on
-- login), and when either of you gets a reminder the other gets it too.
--
-- Slash commands (/cardio or /workout):
--   /cardio               show the next workout now
--   /cardio stats        totals done so far
--   /cardio status       what's next, time until the timed reminder, partner
--   /cardio reps <exercise> <n>   e.g. /cardio reps pushups 25
--   /cardio interval <minutes>    time outside dungeons between reminders (default 60)
--   /cardio partner <name>        sync with a friend (no name = stop syncing)
--   /cardio reset        clear totals and restart the rotation

local ADDON = ...

local EXERCISES = {
  { key = "pushups",  name = "Pushups",       reps = 15 },
  { key = "situps",   name = "Situps",        reps = 20 },
  { key = "jacks",    name = "Jumping Jacks", reps = 30 },
  { key = "squats",   name = "Air Squats",    reps = 20 },
}
local ALIASES = {
  pushup = "pushups", pushups = "pushups",
  situp = "situps", situps = "situps",
  jack = "jacks", jacks = "jacks", jumpingjacks = "jacks",
  squat = "squats", squats = "squats", airsquats = "squats",
}

local PREFIX = "CardioPolice"
local TICK = 5                  -- seconds between timer updates
local SNOOZE = 5 * 60           -- seconds
local MIN_DUNGEON_TIME = 5 * 60 -- ignore quick zone-ins/outs

local db
local inDungeon = false
local lastTick
local pendingReason, pendingFromPartner -- reminder waiting for combat to end
local snoozeGen = 0

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff4040Cardio Police|r: " .. msg)
end

local function IsDungeon()
  local inInstance, kind = IsInInstance()
  return inInstance and (kind == "party" or kind == "raid")
end

local function Current()
  local ex = EXERCISES[db.index] or EXERCISES[1]
  return ex, db.reps[ex.key] or ex.reps
end

------------------------------------------------------------------------------
-- Partner sync
------------------------------------------------------------------------------

local function ShortName(name)
  if not name then return nil end
  if Ambiguate then name = Ambiguate(name, "none") else name = name:gsub("%-.*", "") end
  return name:lower()
end

local function Send(msg)
  if not db.partner then return end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(PREFIX, msg, "WHISPER", db.partner)
  elseif SendAddonMessage then
    SendAddonMessage(PREFIX, msg, "WHISPER", db.partner)
  end
end

-- seq:index:pushups:situps:jacks:squats (0 = default reps)
local function StateString()
  local parts = { db.seq, db.index }
  for _, ex in ipairs(EXERCISES) do parts[#parts + 1] = db.reps[ex.key] or 0 end
  return table.concat(parts, ":")
end

local UpdatePopup -- defined with the popup

local function ApplyState(text)
  local fields = { strsplit(":", text) }
  local seq, index = tonumber(fields[1]), tonumber(fields[2])
  if not seq or not index or not EXERCISES[index] or seq <= db.seq then return end
  db.seq, db.index = seq, index
  for i, ex in ipairs(EXERCISES) do
    local n = tonumber(fields[i + 2])
    db.reps[ex.key] = (n and n > 0) and n or nil
  end
  UpdatePopup()
end

-- Call after any change to the rotation position or reps.
local function Changed()
  db.seq = db.seq + 1
  Send("S:" .. StateString())
end

local function Advance()
  db.index = db.index % #EXERCISES + 1
  Changed()
end

local function OnAddonMessage(prefix, msg, _, sender)
  if prefix ~= PREFIX or not db.partner or ShortName(sender) ~= ShortName(db.partner) then return end
  local kind, rest = msg:match("^(%a):(.*)$")
  if kind == "H" then        -- partner logged in: take theirs if newer, send ours back
    ApplyState(rest)
    Send("S:" .. StateString())
  elseif kind == "S" then
    ApplyState(rest)
  elseif kind == "R" then
    CardioPolice_Show(("%s: %s"):format(Ambiguate and Ambiguate(sender, "none") or sender, rest), true)
  end
end

-- Hide "No player named X is currently playing" when the partner is offline.
local function FilterOffline(_, _, msg)
  if db and db.partner and ERR_CHAT_PLAYER_NOT_FOUND_S
     and msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(db.partner) then
    return true
  end
end

------------------------------------------------------------------------------
-- Popup
------------------------------------------------------------------------------

local popup

local function MakeButton(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 24)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function BuildPopup()
  local f = CreateFrame("Frame", "CardioPolicePopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(320, 140)
  f:SetPoint("TOP", 0, -160)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end

  f.reason = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.reason:SetPoint("TOP", 0, -20)

  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  f.text:SetPoint("TOP", f.reason, "BOTTOM", 0, -12)

  f.next = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.next:SetPoint("TOP", f.text, "BOTTOM", 0, -6)

  local done = MakeButton(f, "Done", 90, function()
    local ex, reps = Current()
    db.totals[ex.key] = (db.totals[ex.key] or 0) + reps
    db.sessions = db.sessions + 1
    Print(("Nice! %d %s logged (%d total)."):format(reps, ex.name, db.totals[ex.key]))
    f:Hide()
    Advance()
  end)
  local snooze = MakeButton(f, "Snooze 5m", 90, function()
    f:Hide()
    snoozeGen = snoozeGen + 1
    local gen = snoozeGen
    C_Timer.After(SNOOZE, function()
      if gen == snoozeGen then CardioPolice_Show("Snoozed reminder", true) end
    end)
  end)
  local skip = MakeButton(f, "Skip", 90, function()
    f:Hide()
    Advance()
  end)
  snooze:SetPoint("BOTTOM", 0, 18)
  done:SetPoint("RIGHT", snooze, "LEFT", -6, 0)
  skip:SetPoint("LEFT", snooze, "RIGHT", 6, 0)

  f:Hide()
  return f
end

function UpdatePopup()
  if not popup then return end
  local ex, reps = Current()
  local nextEx = EXERCISES[db.index % #EXERCISES + 1]
  popup.text:SetText(("%d %s"):format(reps, ex.name))
  popup.next:SetText("Next up: " .. nextEx.name)
end

-- quiet: don't pass this reminder on to the partner (it came from them, or
-- it's a snooze coming back).
function CardioPolice_Show(reason, quiet)
  if InCombatLockdown() then
    pendingReason, pendingFromPartner = reason, quiet
    return
  end
  pendingReason = nil
  snoozeGen = snoozeGen + 1 -- a new reminder replaces any snooze
  db.awayTime = 0           -- any reminder restarts the hourly timer
  if not quiet then Send("R:" .. reason) end

  popup = popup or BuildPopup()
  popup.reason:SetText(reason)
  UpdatePopup()
  popup:Show()

  local ex, reps = Current()
  if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
    RaidNotice_AddMessage(RaidWarningFrame, ("Workout time: %d %s"):format(reps, ex.name), ChatTypeInfo["RAID_WARNING"])
  end
end

------------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------------

-- The run is over: remind if it was a real run, not a quick zone-in.
local function FinishDungeon()
  db.midRun = false
  if db.dungeonTime >= MIN_DUNGEON_TIME then
    CardioPolice_Show("Dungeon done!")
  end
  db.dungeonTime = 0
end

local function CheckZone()
  local now = IsDungeon()
  if now == inDungeon then return end
  inDungeon = now
  db.inDungeon = now

  if now then
    -- Coming back from a corpse run keeps the run's time going.
    if not db.midRun then db.dungeonTime = 0 end
    db.midRun = false
    return
  end

  -- Left a dungeon. Wait a moment so death/ghost state is settled: a corpse
  -- run (ghost outside the instance) isn't the end of the dungeon.
  C_Timer.After(3, function()
    if IsDungeon() then return end
    if UnitIsDeadOrGhost("player") then
      db.midRun = true
    else
      FinishDungeon()
    end
  end)
end

-- Resurrected outside the dungeon (spirit healer) after a wipe: run's over.
local function OnUnghost()
  if not db.midRun then return end
  C_Timer.After(3, function()
    if db.midRun and not IsDungeon() and not UnitIsDeadOrGhost("player") then
      FinishDungeon()
    end
  end)
end

local function Tick()
  local t = GetTime()
  local dt = t - lastTick
  lastTick = t
  if inDungeon then
    db.dungeonTime = db.dungeonTime + dt
  elseif not UnitIsAFK("player") and not db.midRun then
    db.awayTime = db.awayTime + dt
    if db.awayTime >= db.interval * 60 and not (popup and popup:IsShown()) then
      CardioPolice_Show("An hour without a dungeon")
    end
  end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_UNGHOST")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
  local arg1 = ...
  if event == "ADDON_LOADED" and arg1 == ADDON then
    CardioPoliceDB = CardioPoliceDB or {}
    db = CardioPoliceDB
    db.index = db.index or 1
    db.seq = db.seq or 0
    db.reps = db.reps or {}
    db.totals = db.totals or {}
    db.sessions = db.sessions or 0
    db.interval = db.interval or 60
    db.awayTime = db.awayTime or 0
    db.dungeonTime = db.dungeonTime or 0
    inDungeon = db.inDungeon or false -- restores state across /reload and relog
    lastTick = GetTime()
    C_Timer.NewTicker(TICK, Tick)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
      RegisterAddonMessagePrefix(PREFIX)
    end
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterOffline)
  elseif not db then
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    local isLogin, isReload = ...
    if isLogin or isReload then Send("H:" .. StateString()) end
    CheckZone()
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    CheckZone()
  elseif event == "PLAYER_UNGHOST" then
    OnUnghost()
  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)
  elseif event == "PLAYER_REGEN_ENABLED" and pendingReason then
    CardioPolice_Show(pendingReason, pendingFromPartner)
  end
end)

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------

SLASH_CARDIOPOLICE1 = "/cardio"
SLASH_CARDIOPOLICE2 = "/workout"
SlashCmdList.CARDIOPOLICE = function(msg)
  msg = strtrim(msg or "")
  local cmd, a, b = strsplit(" ", msg)
  cmd = (cmd or ""):lower()
  if cmd == "" then
    CardioPolice_Show("Workout on demand")
  elseif cmd == "stats" then
    Print(("%d workouts done."):format(db.sessions))
    for _, ex in ipairs(EXERCISES) do
      Print(("  %s: %d"):format(ex.name, db.totals[ex.key] or 0))
    end
  elseif cmd == "reps" then
    local key, n = ALIASES[(a or ""):lower():gsub("[%s_-]", "")], tonumber(b)
    if not key or not n or n < 1 then
      Print("Usage: /cardio reps <pushups|situps|jacks|squats> <number>")
      return
    end
    db.reps[key] = math.floor(n)
    Print(("%s set to %d reps."):format(key, db.reps[key]))
    Changed()
    UpdatePopup()
  elseif cmd == "interval" then
    local n = tonumber(a)
    if not n or n < 1 then Print("Usage: /cardio interval <minutes>") return end
    db.interval = n
    Print(("Timed reminder every %d minutes outside dungeons."):format(n))
  elseif cmd == "partner" then
    if not a or a == "" then
      db.partner = nil
      Print("Partner sync off.")
      return
    end
    db.partner = a:sub(1, 1):upper() .. a:sub(2)
    Print(("Syncing with %s. They need to run /cardio partner %s too."):format(db.partner, UnitName("player")))
    Send("H:" .. StateString())
  elseif cmd == "status" then
    local ex, reps = Current()
    local left = math.max(0, db.interval * 60 - db.awayTime)
    Print(("Next: %d %s. %s"):format(reps, ex.name,
      inDungeon and "In a dungeon - reminder when you finish."
        or ("Timed reminder in %d min."):format(math.ceil(left / 60))))
    Print(db.partner and ("Partner: " .. db.partner) or "No partner set.")
  elseif cmd == "reset" then
    db.totals, db.sessions, db.awayTime = {}, 0, 0
    db.index = 1
    Changed()
    UpdatePopup()
    Print("Totals cleared and rotation restarted.")
  else
    Print("/cardio [stats | status | reps <exercise> <n> | interval <min> | partner <name> | reset]")
  end
end
