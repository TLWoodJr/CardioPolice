-- Cardio Police: pops up a workout after each dungeon and after every hour
-- spent outside dungeons, cycling through a rotation of exercises.
--
-- The rotation (exercises, order, reps) and the timing are all editable in
-- the settings window: /cardio config, or left-click the minimap button.
--
-- Partner sync: both players run /cardio partner <name>. The rotation and
-- its position stay in sync (newest change wins, catching up on login), and
-- when either of you gets a reminder the other gets it too.
--
-- Slash commands (/cardio or /workout): see /cardio help.

local ADDON = ...

local DEFAULT_ROTATION = {
  { name = "Pushups",       reps = 15 },
  { name = "Situps",        reps = 20 },
  { name = "Jumping Jacks", reps = 30 },
  { name = "Air Squats",    reps = 20 },
}
local DEFAULTS = {
  interval = 60,       -- minutes outside dungeons between reminders
  timed = true,        -- timed reminders on
  afterDungeon = true, -- reminder when a dungeon run ends
  minDungeon = 5,      -- minutes in a dungeon before leaving it counts as a run
  snooze = 5,          -- minutes
  sound = "siren",     -- "siren", "warning" or "none"
  flash = true,        -- red/blue screen border
}

local MAX_EXERCISES = 8 -- keeps the sync message under the 255 byte limit
local MAX_NAME = 20
local MAX_REPS = 999

local PREFIX = "CardioPolice"
local TICK = 5 -- seconds between timer updates
local SIREN = "Interface\\AddOns\\" .. ADDON .. "\\Siren.ogg"
local ICON = "Interface\\Icons\\Ability_Rogue_Sprint"
local FLASH_TIME = 3.2 -- seconds, same length as the siren

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

-- The exercise that's up now, and the one after it.
local function Current()
  local rot = db.rotation
  local i = rot[db.index] and db.index or 1
  return rot[i], rot[i % #rot + 1]
end

-- Names travel in sync messages, so keep out the separators and escapes.
local function CleanName(s)
  s = (s or ""):gsub("[:,=|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #s > MAX_NAME then
    s = s:sub(1, MAX_NAME):gsub("[\192-\255][\128-\191]*$", ""):gsub("%s+$", "")
  end
  return s
end

local function Norm(s) return (s:lower():gsub("[^%w]", "")) end
local function Singular(s) return (s:gsub("s$", "")) end

-- Find a rotation entry by loose name: "pushup", "jacks", "air squats"...
local function FindExercise(query)
  local q = Norm(query or "")
  if q == "" then return end
  local partial
  for i, ex in ipairs(db.rotation) do
    local n = Norm(ex.name)
    if n == q or Singular(n) == Singular(q) then return i end
    if n:find(q, 1, true) then partial = partial and -1 or i end
  end
  if partial and partial > 0 then return partial end
end

local function TimerStatus()
  if inDungeon then
    return db.afterDungeon and "In a dungeon - reminder when you finish." or "In a dungeon."
  end
  if not db.timed then return "Timed reminders are off." end
  local left = math.max(0, db.interval * 60 - db.awayTime)
  return ("Timed reminder in %d min."):format(math.ceil(left / 60))
end

local Refresh -- updates any open windows; defined after the UI

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

-- seq:index:Name=reps,Name=reps,...
local function StateString()
  local list = {}
  for i, ex in ipairs(db.rotation) do list[i] = ex.name .. "=" .. ex.reps end
  return ("%d:%d:%s"):format(db.seq, db.index, table.concat(list, ","))
end

local function ApplyState(text)
  local seq, index, list = (text or ""):match("^(%d+):(%d+):(.*)$")
  seq, index = tonumber(seq), tonumber(index)
  if not seq or seq <= db.seq then return end
  local rot = {}
  for item in list:gmatch("[^,]+") do
    local name, reps = item:match("^(.-)=(%d+)$")
    name, reps = CleanName(name), tonumber(reps)
    if name ~= "" and reps and reps >= 1 and #rot < MAX_EXERCISES then
      rot[#rot + 1] = { name = name, reps = math.min(reps, MAX_REPS) }
    end
  end
  if #rot == 0 or index < 1 or index > #rot then return end
  db.seq, db.index, db.rotation = seq, index, rot
  Refresh()
end

-- Call after any change to the rotation or its position.
local function Changed()
  db.seq = db.seq + 1
  Send("T:" .. StateString())
  Refresh()
end

local function Advance()
  db.index = db.index % #db.rotation + 1
  Changed()
end

local function OnAddonMessage(prefix, msg, _, sender)
  if prefix ~= PREFIX or not db.partner or ShortName(sender) ~= ShortName(db.partner) then return end
  local kind, rest = msg:match("^(%a):(.*)$")
  if kind == "J" then        -- partner logged in: take theirs if newer, send ours back
    ApplyState(rest)
    Send("T:" .. StateString())
  elseif kind == "T" then
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
-- Rotation edits
------------------------------------------------------------------------------

local function AddExercise(name, reps)
  if #db.rotation >= MAX_EXERCISES then return false end
  table.insert(db.rotation, { name = name, reps = reps })
  Changed()
  return true
end

local function RemoveExercise(i)
  local rot = db.rotation
  if #rot <= 1 or not rot[i] then return false end
  table.remove(rot, i)
  if db.index > i then db.index = db.index - 1 end
  if db.index > #rot then db.index = 1 end
  Changed()
  return true
end

-- Swap two entries; the "up next" marker follows the exercise it was on.
local function SwapExercises(i, j)
  local rot = db.rotation
  if not rot[i] or not rot[j] then return end
  rot[i], rot[j] = rot[j], rot[i]
  if db.index == i then db.index = j elseif db.index == j then db.index = i end
  Changed()
end

local function UseDefaultRotation()
  db.rotation = {}
  for i, ex in ipairs(DEFAULT_ROTATION) do db.rotation[i] = { name = ex.name, reps = ex.reps } end
  db.index = 1
  Changed()
end

------------------------------------------------------------------------------
-- Alert: siren and flashing red/blue screen border
------------------------------------------------------------------------------

local RED, BLUE = { 1, 0.05, 0.05 }, { 0.1, 0.35, 1 }
local flash

-- Edge glow: solid at the screen edge, fading toward the middle.
local function Glow(tex, orient, outerIsMin, color, a)
  local r, g, b = color[1], color[2], color[3]
  local a1, a2 = outerIsMin and a or 0, outerIsMin and 0 or a
  if tex.SetGradientAlpha then
    tex:SetGradientAlpha(orient, r, g, b, a1, r, g, b, a2)
  elseif CreateColor then
    tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
  else
    tex:SetVertexColor(r, g, b, a * 0.5)
  end
end

local function BuildFlash()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetAllPoints(UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(false)
  local function Tex(p1, r1, p2, r2)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetBlendMode("ADD")
    t:SetPoint(p1, f, r1)
    t:SetPoint(p2, f, r2)
    return t
  end
  -- A thin glow down the left and right edges, fading out toward the middle.
  local THICKNESS = 0.05 -- fraction of the screen's shorter side
  f.left = Tex("TOPLEFT", "TOPLEFT", "BOTTOMLEFT", "BOTTOMLEFT")
  f.right = Tex("TOPRIGHT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMRIGHT")
  local function Size(self, w, h)
    local s = math.min(w, h) * THICKNESS
    self.left:SetWidth(s)
    self.right:SetWidth(s)
  end
  f:SetScript("OnSizeChanged", Size)
  Size(f, UIParent:GetWidth(), UIParent:GetHeight())

  function f:Paint(swap, a)
    Glow(self.left, "HORIZONTAL", true, swap and BLUE or RED, a)
    Glow(self.right, "HORIZONTAL", false, swap and RED or BLUE, a)
  end

  -- Red | blue, then blue | red, back and forth, double-strobing each time.
  local HALF = 0.35
  f:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + elapsed
    local t = self.t
    if t >= FLASH_TIME then self:Hide() return end
    local swap = math.floor(t / HALF) % 2 == 1
    local sub = (t % HALF) / HALF
    local a = (sub < 0.35 or (sub > 0.5 and sub < 0.85)) and 0.4 or 0.08
    local key = tostring(swap) .. a
    if key ~= self.key then
      self.key = key
      self:Paint(swap, a)
    end
    self:SetAlpha(math.min(1, (FLASH_TIME - t) / 0.4))
  end)
  f:Hide()
  return f
end

local function Flash()
  flash = flash or BuildFlash()
  flash.t, flash.key = 0, nil
  flash:SetAlpha(1)
  flash:Show()
end

local function PlayAlert()
  if db.sound == "siren" then
    PlaySoundFile(SIREN, "Master")
  elseif db.sound == "warning" and SOUNDKIT and SOUNDKIT.RAID_WARNING then
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
  end
  if db.flash then Flash() end
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

local function DialogBackdrop(f)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end
end

local function Draggable(f)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
end

local function BuildPopup()
  local f = CreateFrame("Frame", "CardioPolicePopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(330, 140)
  f:SetPoint("TOP", 0, -160)
  f:SetFrameStrata("DIALOG")
  Draggable(f)
  DialogBackdrop(f)

  f.reason = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.reason:SetPoint("TOP", 0, -20)

  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  f.text:SetPoint("TOP", f.reason, "BOTTOM", 0, -12)

  f.next = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.next:SetPoint("TOP", f.text, "BOTTOM", 0, -6)

  local done = MakeButton(f, "Done", 96, function()
    local ex = Current()
    db.totals[ex.name] = (db.totals[ex.name] or 0) + ex.reps
    db.sessions = db.sessions + 1
    Print(("Nice! %d %s logged (%d total)."):format(ex.reps, ex.name, db.totals[ex.name]))
    f:Hide()
    Advance()
  end)
  f.snooze = MakeButton(f, "Snooze", 96, function()
    f:Hide()
    snoozeGen = snoozeGen + 1
    local gen = snoozeGen
    C_Timer.After(db.snooze * 60, function()
      if gen == snoozeGen then CardioPolice_Show("Snoozed reminder", true) end
    end)
  end)
  local skip = MakeButton(f, "Skip", 96, function()
    f:Hide()
    Advance()
  end)
  f.snooze:SetPoint("BOTTOM", 0, 18)
  done:SetPoint("RIGHT", f.snooze, "LEFT", -6, 0)
  skip:SetPoint("LEFT", f.snooze, "RIGHT", 6, 0)

  f:Hide()
  return f
end

local function UpdatePopup()
  if not popup then return end
  local ex, nextEx = Current()
  popup.text:SetText(("%d %s"):format(ex.reps, ex.name))
  popup.next:SetText("Next up: " .. nextEx.name)
  popup.snooze:SetText(("Snooze %dm"):format(db.snooze))
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
  db.awayTime = 0           -- any reminder restarts the timed reminder
  if not quiet then Send("R:" .. reason) end

  popup = popup or BuildPopup()
  popup.reason:SetText(reason)
  UpdatePopup()
  popup:Show()

  PlayAlert()
  local ex = Current()
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
    RaidNotice_AddMessage(RaidWarningFrame, ("Workout time: %d %s"):format(ex.reps, ex.name), ChatTypeInfo["RAID_WARNING"])
  end
end

------------------------------------------------------------------------------
-- Settings window
------------------------------------------------------------------------------

local config
local UpdateMinimapButton -- defined with the minimap button

local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetText(text)
  return fs
end

local function TextBox(parent, width, maxLetters, numeric)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  e:SetMaxLetters(maxLetters)
  if numeric then
    e:SetNumeric(true)
    e:SetJustifyH("CENTER")
  end
  e:SetScript("OnEnterPressed", e.ClearFocus)
  e:SetScript("OnEscapePressed", function(self)
    self.cancel = true
    self:ClearFocus()
  end)
  e:SetScript("OnEditFocusLost", function(self)
    if not self.cancel then self:Commit(self:GetText()) end
    self.cancel = nil
    self:Load()
  end)
  return e
end

-- A number box: get() returns the value, set(n) is called with a valid one.
local function NumberBox(parent, width, min, max, get, set)
  local e = TextBox(parent, width, #tostring(max), true)
  function e:Commit(text)
    local n = tonumber(text)
    if n and n >= min then
      n = math.min(math.floor(n), max)
      if n ~= get() then set(n) end
    end
  end
  function e:Load()
    if not self:HasFocus() then self:SetText(tostring(get() or "")) end
  end
  return e
end

local function Check(parent, text, get, set)
  local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(26, 26)
  c.label = Label(c, text)
  c.label:SetPoint("LEFT", c, "RIGHT", 2, 1)
  c:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    Refresh()
  end)
  function c:Load() self:SetChecked(get() and true or false) end
  return c
end

local function IconButton(parent, size, tex, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b:SetNormalTexture(tex .. "-Up")
  b:SetPushedTexture(tex .. "-Down")
  b:SetDisabledTexture(tex .. "-Disabled")
  b:SetHighlightTexture(tex .. "-Highlight", "ADD")
  b:SetScript("OnClick", onClick)
  return b
end

local function Tooltip(frame, text)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", GameTooltip_Hide)
end

local function BuildRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(360, 24)
  row.i = i

  -- Row number; click it to make this exercise the next one.
  row.num = CreateFrame("Button", nil, row)
  row.num:SetSize(24, 20)
  row.num:SetPoint("LEFT")
  row.num.text = Label(row.num, i .. ".", "GameFontNormal")
  row.num.text:SetAllPoints()
  row.num.text:SetJustifyH("RIGHT")
  row.num:SetScript("OnClick", function()
    if db.index ~= i then
      db.index = i
      Changed()
    end
  end)
  Tooltip(row.num, "Click to make this the next exercise.")

  row.name = TextBox(row, 170, MAX_NAME)
  row.name:SetPoint("LEFT", row.num, "RIGHT", 14, 0)
  function row.name:Commit(text)
    local ex, name = db.rotation[i], CleanName(text)
    if ex and name ~= "" and name ~= ex.name then
      ex.name = name
      Changed()
    end
  end
  function row.name:Load()
    if not self:HasFocus() and db.rotation[i] then self:SetText(db.rotation[i].name) end
  end

  row.reps = NumberBox(row, 40, 1, MAX_REPS,
    function() return db.rotation[i] and db.rotation[i].reps end,
    function(n) if db.rotation[i] then db.rotation[i].reps = n; Changed() end end)
  row.reps:SetPoint("LEFT", row.name, "RIGHT", 12, 0)

  row.up = IconButton(row, 22, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton", function()
    SwapExercises(i, i - 1)
  end)
  row.up:SetPoint("LEFT", row.reps, "RIGHT", 8, 0)
  row.down = IconButton(row, 22, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton", function()
    SwapExercises(i, i + 1)
  end)
  row.down:SetPoint("LEFT", row.up, "RIGHT", 0, 0)
  row.remove = IconButton(row, 26, "Interface\\Buttons\\UI-Panel-MinimizeButton", function()
    RemoveExercise(i)
  end)
  row.remove:SetPoint("LEFT", row.down, "RIGHT", 2, 0)
  Tooltip(row.remove, "Remove from the rotation")

  function row:Load()
    local n = #db.rotation
    if i > n then self:Hide() return end
    self:Show()
    self.name:Load()
    self.reps:Load()
    if i == db.index then
      self.num.text:SetTextColor(0.2, 1, 0.2)
    else
      self.num.text:SetTextColor(1, 0.82, 0)
    end
    self.up:SetEnabled(i > 1)
    self.down:SetEnabled(i < n)
    self.remove:SetEnabled(n > 1)
  end
  return row
end

local function BuildConfig()
  local f = CreateFrame("Frame", "CardioPoliceConfig", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(400, 610)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  Draggable(f)
  DialogBackdrop(f)
  tinsert(UISpecialFrames, "CardioPoliceConfig") -- Escape closes it

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  local title = Label(f, "Cardio Police", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -20)

  local loaders = {}
  local function Add(widget) loaders[#loaders + 1] = widget; return widget end
  local function Header(text, y)
    local h = Label(f, text, "GameFontNormal")
    h:SetPoint("TOPLEFT", 24, y)
    return h
  end

  -- Rotation ---------------------------------------------------------------
  local y = -50
  Header("Rotation", y)
  local hint = Label(f, "Green = up next", "GameFontDisableSmall")
  hint:SetPoint("TOPRIGHT", -28, y - 2)
  local repsHead = Label(f, "Reps", "GameFontDisableSmall")
  repsHead:SetPoint("TOPLEFT", 252, y - 2)
  y = y - 20
  for i = 1, MAX_EXERCISES do
    local row = Add(BuildRow(f, i))
    row:SetPoint("TOPLEFT", 20, y - (i - 1) * 26)
  end
  y = y - MAX_EXERCISES * 26 - 4

  f.add = MakeButton(f, "Add exercise", 120, function()
    if AddExercise("New exercise", 10) then
      local row = loaders[#db.rotation]
      row.name:SetFocus()
      row.name:HighlightText()
    end
  end)
  f.add:SetPoint("TOPLEFT", 24, y)
  local defaults = MakeButton(f, "Use defaults", 120, function()
    UseDefaultRotation()
    Print("Rotation reset to the defaults.")
  end)
  defaults:SetPoint("LEFT", f.add, "RIGHT", 8, 0)

  -- Timing -----------------------------------------------------------------
  y = y - 40
  Header("Timing", y)
  y = y - 20

  -- [x] <before> [n] <after>
  local function CheckNumberLine(before, after, flag, key, min, max)
    local c = Add(Check(f, before, function() return db[flag] end, function(v) db[flag] = v end))
    c:SetPoint("TOPLEFT", 20, y)
    local box = Add(NumberBox(f, 40, min, max, function() return db[key] end, function(n) db[key] = n end))
    box:SetPoint("LEFT", c.label, "RIGHT", 10, 0)
    local tail = Label(f, after)
    tail:SetPoint("LEFT", box, "RIGHT", 6, 0)
    y = y - 28
  end
  CheckNumberLine("Every", "minutes outside dungeons", "timed", "interval", 1, 999)
  CheckNumberLine("After dungeons of at least", "minutes", "afterDungeon", "minDungeon", 0, 999)

  local snoozeLabel = Label(f, "Snooze for")
  snoozeLabel:SetPoint("TOPLEFT", 50, y - 6)
  local snooze = Add(NumberBox(f, 40, 1, 999, function() return db.snooze end, function(n) db.snooze = n end))
  snooze:SetPoint("LEFT", snoozeLabel, "RIGHT", 10, 0)
  Label(f, "minutes"):SetPoint("LEFT", snooze, "RIGHT", 6, 0)
  y = y - 30

  -- Alerts -----------------------------------------------------------------
  y = y - 10
  Header("Alerts", y)
  y = y - 20

  local soundLabel = Label(f, "Sound:")
  soundLabel:SetPoint("TOPLEFT", 24, y - 6)
  local x = 70
  for _, opt in ipairs({ { "siren", "Police siren" }, { "warning", "Raid warning" }, { "none", "None" } }) do
    local c = Add(Check(f, opt[2], function() return db.sound == opt[1] end, function() db.sound = opt[1] end))
    c:SetPoint("TOPLEFT", x, y)
    x = x + 34 + c.label:GetStringWidth() + 10
  end
  y = y - 28

  Add(Check(f, "Flash red and blue on the screen edges",
    function() return db.flash end, function(v) db.flash = v end)):SetPoint("TOPLEFT", 20, y)
  y = y - 28
  Add(Check(f, "Show minimap button",
    function() return not db.minimap.hide end,
    function(v) db.minimap.hide = not v; UpdateMinimapButton() end)):SetPoint("TOPLEFT", 20, y)

  local test = MakeButton(f, "Test alert", 110, PlayAlert)
  test:SetPoint("BOTTOMLEFT", 24, 22)
  local now = MakeButton(f, "Workout now", 110, function() CardioPolice_Show("Workout on demand") end)
  now:SetPoint("LEFT", test, "RIGHT", 8, 0)

  function f:Load()
    for _, w in ipairs(loaders) do w:Load() end
    self.add:SetEnabled(#db.rotation < MAX_EXERCISES)
  end
  f:SetScript("OnShow", f.Load)
  f:Hide()
  return f
end

local function ShowConfig(show)
  config = config or BuildConfig()
  if show == nil then show = not config:IsShown() end
  if show then config:Show() else config:Hide() end
end

function Refresh()
  UpdatePopup()
  if config and config:IsShown() then config:Load() end
end

-- An entry in the game's own AddOns options list that opens the window.
local function RegisterOptionsPanel()
  local panel = CreateFrame("Frame")
  panel.name = "Cardio Police"
  local t = Label(panel, "Cardio Police", "GameFontNormalLarge")
  t:SetPoint("TOPLEFT", 16, -16)
  local b = MakeButton(panel, "Open settings", 140, function() ShowConfig(true) end)
  b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -12)
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

------------------------------------------------------------------------------
-- Minimap button
------------------------------------------------------------------------------

local minimapButton

local function PlaceMinimapButton()
  local a = math.rad(db.minimap.angle)
  local x, y = math.cos(a), math.sin(a)
  local r = Minimap:GetWidth() / 2 + 10
  if GetMinimapShape and GetMinimapShape() == "SQUARE" then
    local m = math.max(math.abs(x), math.abs(y))
    x, y, r = x / m, y / m, Minimap:GetWidth() / 2 + 4
  end
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", x * r, y * r)
end

local function DragMinimapButton()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local dx, dy = px / scale - mx, py / scale - my
  db.minimap.angle = math.deg((math.atan2 or math.atan)(dy, dx))
  PlaceMinimapButton()
end

local function BuildMinimapButton()
  local b = CreateFrame("Button", "CardioPoliceMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      CardioPolice_Show("Workout on demand")
    else
      ShowConfig()
    end
  end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", DragMinimapButton)
    GameTooltip:Hide()
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    local ex = Current()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Cardio Police")
    GameTooltip:AddLine(("Next: %d %s"):format(ex.reps, ex.name), 1, 1, 1)
    GameTooltip:AddLine(TimerStatus(), 1, 1, 1)
    if db.partner then GameTooltip:AddLine("Partner: " .. db.partner, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: settings", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: workout now", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  return b
end

function UpdateMinimapButton()
  if db.minimap.hide then
    if minimapButton then minimapButton:Hide() end
    return
  end
  minimapButton = minimapButton or BuildMinimapButton()
  PlaceMinimapButton()
  minimapButton:Show()
end

------------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------------

-- The run is over: remind if it was a real run, not a quick zone-in.
local function FinishDungeon()
  db.midRun = false
  if db.afterDungeon and db.dungeonTime >= db.minDungeon * 60 then
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

local function TimedReason()
  local m = db.interval
  if m == 60 then return "An hour without a dungeon" end
  if m % 60 == 0 then return ("%d hours without a dungeon"):format(m / 60) end
  return ("%d minutes without a dungeon"):format(m)
end

local function Tick()
  local t = GetTime()
  local dt = t - lastTick
  lastTick = t
  if inDungeon then
    db.dungeonTime = db.dungeonTime + dt
  elseif db.timed and not UnitIsAFK("player") and not db.midRun then
    db.awayTime = db.awayTime + dt
    if db.awayTime >= db.interval * 60 and not (popup and popup:IsShown()) then
      CardioPolice_Show(TimedReason())
    end
  end
end

------------------------------------------------------------------------------
-- Saved variables
------------------------------------------------------------------------------

local function LoadDB()
  CardioPoliceDB = CardioPoliceDB or {}
  db = CardioPoliceDB
  db.index = db.index or 1
  db.seq = db.seq or 0
  db.totals = db.totals or {}
  db.sessions = db.sessions or 0
  db.awayTime = db.awayTime or 0
  db.dungeonTime = db.dungeonTime or 0
  db.minimap = db.minimap or {}
  db.minimap.angle = db.minimap.angle or 210
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end

  -- Older versions had a fixed rotation, with reps and totals keyed by id.
  if not db.rotation then
    local oldKeys = { "pushups", "situps", "jacks", "squats" }
    db.rotation = {}
    for i, ex in ipairs(DEFAULT_ROTATION) do
      local key = oldKeys[i]
      db.rotation[i] = { name = ex.name, reps = (db.reps and db.reps[key]) or ex.reps }
      if db.totals[key] then
        db.totals[ex.name] = (db.totals[ex.name] or 0) + db.totals[key]
        db.totals[key] = nil
      end
    end
    db.reps = nil
  end
  if #db.rotation == 0 then
    for i, ex in ipairs(DEFAULT_ROTATION) do db.rotation[i] = { name = ex.name, reps = ex.reps } end
  end
  if not db.rotation[db.index] then db.index = 1 end
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
    LoadDB()
    inDungeon = db.inDungeon or false -- restores state across /reload and relog
    lastTick = GetTime()
    C_Timer.NewTicker(TICK, Tick)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
      RegisterAddonMessagePrefix(PREFIX)
    end
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterOffline)
    UpdateMinimapButton()
    pcall(RegisterOptionsPanel)
  elseif not db then
    return
  elseif event == "PLAYER_ENTERING_WORLD" then
    local isLogin, isReload = ...
    if isLogin or isReload then Send("J:" .. StateString()) end
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

local HELP = {
  "/cardio - show the next workout now",
  "/cardio config - open the settings window",
  "/cardio rotation - list the rotation",
  "/cardio reps <exercise> <n> - set reps, e.g. /cardio reps squats 25",
  "/cardio add <exercise> <n> - add an exercise, e.g. /cardio add burpees 10",
  "/cardio remove <exercise> - take one out of the rotation",
  "/cardio interval <min> - time outside dungeons between reminders (0 = off)",
  "/cardio dungeon <min> - shortest dungeon run that counts (off = no dungeon reminders)",
  "/cardio snooze <min> - snooze length",
  "/cardio sound <siren|warning|none> - alert sound",
  "/cardio flash - toggle the red/blue screen flash",
  "/cardio minimap - toggle the minimap button",
  "/cardio test - play the alert",
  "/cardio stats | status | partner <name> | reset",
}

-- Set a minutes value. flag (optional) is the on/off switch that goes with
-- it, turned off by "off" (or 0 when zero isn't a valid value).
local function SetMinutes(text, flag, key, what, allowZero)
  local n = tonumber(text)
  if flag and (text == "off" or (n == 0 and not allowZero)) then
    db[flag] = false
    Print(what .. " off.")
    return true
  end
  if not n or n < 0 or (n == 0 and not allowZero) then return false end
  db[key] = math.min(math.floor(n), 999)
  if flag then db[flag] = true end
  return true
end

SLASH_CARDIOPOLICE1 = "/cardio"
SLASH_CARDIOPOLICE2 = "/workout"
SlashCmdList.CARDIOPOLICE = function(msg)
  msg = strtrim(msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  local arg = rest:lower()

  if cmd == "" then
    CardioPolice_Show("Workout on demand")
  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    ShowConfig(true)
  elseif cmd == "help" then
    for _, line in ipairs(HELP) do Print(line) end
  elseif cmd == "stats" then
    Print(("%d workouts done."):format(db.sessions))
    local shown = {}
    for _, ex in ipairs(db.rotation) do
      Print(("  %s: %d"):format(ex.name, db.totals[ex.name] or 0))
      shown[ex.name] = true
    end
    local others = {}
    for name in pairs(db.totals) do if not shown[name] then others[#others + 1] = name end end
    table.sort(others)
    for _, name in ipairs(others) do Print(("  %s: %d (not in rotation)"):format(name, db.totals[name])) end
  elseif cmd == "rotation" or cmd == "list" then
    for i, ex in ipairs(db.rotation) do
      Print(("%s%d. %d %s"):format(i == db.index and "> " or "  ", i, ex.reps, ex.name))
    end
  elseif cmd == "reps" then
    local name, n = rest:match("^(.-)%s+(%d+)$")
    local i = FindExercise(name)
    n = tonumber(n)
    if not i or not n or n < 1 then
      Print("Usage: /cardio reps <exercise> <number>. See /cardio rotation for names.")
      return
    end
    db.rotation[i].reps = math.min(n, MAX_REPS)
    Print(("%s set to %d reps."):format(db.rotation[i].name, db.rotation[i].reps))
    Changed()
  elseif cmd == "add" then
    local name, n = rest:match("^(.-)%s+(%d+)$")
    name, n = CleanName(name), tonumber(n)
    if name == "" or not n or n < 1 then
      Print("Usage: /cardio add <exercise> <reps>, e.g. /cardio add Burpees 10")
    elseif not AddExercise(name, math.min(n, MAX_REPS)) then
      Print(("The rotation is full (%d exercises)."):format(MAX_EXERCISES))
    else
      Print(("Added %d %s to the rotation."):format(n, name))
    end
  elseif cmd == "remove" then
    local i = FindExercise(rest)
    local name = i and db.rotation[i].name
    if not i then
      Print("Usage: /cardio remove <exercise>. See /cardio rotation for names.")
    elseif not RemoveExercise(i) then
      Print("The rotation needs at least one exercise.")
    else
      Print(("Removed %s from the rotation."):format(name))
    end
  elseif cmd == "interval" then
    if not SetMinutes(arg, "timed", "interval", "Timed reminders") then
      Print("Usage: /cardio interval <minutes> (0 = off)")
    elseif db.timed then
      Print(("Timed reminder every %d minutes outside dungeons."):format(db.interval))
    end
    Refresh()
  elseif cmd == "dungeon" then
    if not SetMinutes(arg, "afterDungeon", "minDungeon", "Dungeon reminders", true) then
      Print("Usage: /cardio dungeon <minutes> (off = no dungeon reminders)")
    elseif db.afterDungeon then
      Print(("Reminder after dungeon runs of at least %d minutes."):format(db.minDungeon))
    end
    Refresh()
  elseif cmd == "snooze" then
    if not SetMinutes(arg, nil, "snooze", "Snooze") then
      Print("Usage: /cardio snooze <minutes>")
    else
      Print(("Snooze lasts %d minutes."):format(db.snooze))
    end
    Refresh()
  elseif cmd == "sound" then
    local pick = ({ siren = "siren", warning = "warning", raid = "warning", none = "none", off = "none" })[arg]
    if not pick then Print("Usage: /cardio sound <siren|warning|none>") return end
    db.sound = pick
    Print("Alert sound: " .. pick .. ".")
    Refresh()
  elseif cmd == "flash" then
    db.flash = not db.flash
    Print("Screen flash " .. (db.flash and "on." or "off."))
    Refresh()
  elseif cmd == "minimap" then
    db.minimap.hide = not db.minimap.hide
    UpdateMinimapButton()
    Print("Minimap button " .. (db.minimap.hide and "hidden." or "shown."))
    Refresh()
  elseif cmd == "test" then
    PlayAlert()
  elseif cmd == "partner" then
    if rest == "" then
      db.partner = nil
      Print("Partner sync off.")
      return
    end
    db.partner = rest:sub(1, 1):upper() .. rest:sub(2)
    Print(("Syncing with %s. They need to run /cardio partner %s too."):format(db.partner, UnitName("player")))
    Send("J:" .. StateString())
  elseif cmd == "status" then
    local ex = Current()
    Print(("Next: %d %s. %s"):format(ex.reps, ex.name, TimerStatus()))
    Print(db.partner and ("Partner: " .. db.partner) or "No partner set.")
  elseif cmd == "reset" then
    db.totals, db.sessions, db.awayTime = {}, 0, 0
    db.index = 1
    Changed()
    Print("Totals cleared and rotation restarted.")
  else
    Print("Unknown command. /cardio help lists them all.")
  end
end
