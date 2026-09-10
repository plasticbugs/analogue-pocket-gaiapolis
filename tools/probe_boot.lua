local f = 0
local snapdir = "artifacts/snap"
local plan = {}
-- frames at which to snapshot (attract mode)
for _,n in ipairs({120, 300, 600, 900, 1200, 1500, 1800, 2100, 2400, 2700, 3000}) do plan[n]=true end
local stop = 3100

emu.add_machine_frame_notifier(function()
  f = f + 1
  if plan[f] then
    manager.machine.video:snapshot()
  end
  if f >= stop then manager.machine:exit() end
end)
