for _, opt in {"count","collect","step","isrunning","stop","restart","setpause"} do
	local ok, r = pcall(collectgarbage, opt)
	print(opt, ok, r)
end
print(typeof(os.clock()), os.clock())
