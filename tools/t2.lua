_G.K={}
local f=0
_G.K.n = emu.add_machine_frame_notifier(function() f=f+1 end)
_G.K.s = emu.add_machine_stop_notifier(function()
  print(string.format("STOP frames=%d emutime=%s", f, tostring(manager.machine.time.seconds)))
  io.stdout:flush()
end)
