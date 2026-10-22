-- REAPER: Actions > Show action list > New action > Load ReaScript.
-- Creates a new project tab, leaving existing projects open.
local arp_name = "Arp Stick"
local available = false
local i = 0
while true do
  local ok, name = reaper.EnumInstalledFX(i)
  if not ok then break end
  if name:find(arp_name, 1, true) then available = true; arp_name = name; break end
  i = i + 1
end
if not available then
  reaper.ShowMessageBox("Arp Stick was not found. Install it, then restart REAPER or rescan CLAP plugins.", "Arp Stick", 0)
  return
end

reaper.Main_OnCommand(40859, 0) -- New project tab.
reaper.SetCurrentBPM(0, 120, false)
reaper.InsertTrackAtIndex(0, true)
local track = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Arp Stick demo", true)
local arp = reaper.TrackFX_AddByName(track, arp_name, false, -1)
local synth = reaper.TrackFX_AddByName(track, "ReaSynth (Cockos)", false, -1)
if arp < 0 or synth < 0 then
  reaper.ShowMessageBox("Could not load Arp Stick or ReaSynth. Add Arp Stick followed by a MIDI synth manually.", "Arp Stick", 0)
  return
end
reaper.SetMediaTrackInfo_Value(track, "D_VOL", 0.25)
local item = reaper.CreateNewMIDIItemInProj(track, 0, 4, false)
local take = reaper.GetActiveTake(item)
local roots = {60, 57, 53, 55}
for index, key in ipairs(roots) do
  local start = reaper.MIDI_GetPPQPosFromProjTime(take, index - 1)
  local finish = reaper.MIDI_GetPPQPosFromProjTime(take, index - 0.0625)
  reaper.MIDI_InsertNote(take, false, false, start, finish, 0, key, 96, true)
end
reaper.MIDI_Sort(take)
reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "C - A - F - G roots", true)
reaper.GetSet_LoopTimeRange(true, true, 0, 4, false)
reaper.SetEditCurPos(0, true, false)
reaper.SetOnlyTrackSelected(track)
reaper.UpdateArrange()
reaper.Main_OnCommand(40031, 0) -- Zoom to project.
reaper.TrackFX_Show(track, arp, 3)
-- Press Play to hear the arpeggio; this script does not start playback.
