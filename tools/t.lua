_G.K={}
local f=0
_G.K.n = emu.add_machine_frame_notifier(function()
  f=f+1
  if f%600==0 then print("FRAME",f) io.stdout:flush() end
  if f>=4000 then print("EXIT_AT",f) manager.machine:exit() end
end)
_G.K.s = emu.add_machine_stop_notifier(function() print("STOP_NOTIFIER_AT",f) end)
