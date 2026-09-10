_G.K={}
local f=0
local sp = manager.machine.devices[":maincpu"].spaces["program"]
_G.K.tap = sp:install_write_tap(0x430000, 0x430007, "k46", function(offset, data, mask) _G.K.last=data end)
_G.K.n = emu.add_machine_frame_notifier(function() f=f+1 end)
_G.K.s = emu.add_machine_stop_notifier(function()
  print(string.format("STOP frames=%d last=%s", f, tostring(_G.K.last))) io.stdout:flush()
end)
