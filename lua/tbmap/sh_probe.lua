-- Named accumulators in CPU time: the build runs in slices that yield to frames, and a wall clock
-- would count the frames as work.

TBMap = TBMap or {}

TBMap.Probe = { times = {}, open = {}, worst = {} }

function TBMap.Probe.Worst(name, seconds, detail)
	local current = TBMap.Probe.worst[name]

	if not current or seconds > current.seconds then
		TBMap.Probe.worst[name] = { seconds = seconds, detail = detail }
	end
end

function TBMap.Probe.Start(name)
	TBMap.Probe.open[name] = os.clock()
end

function TBMap.Probe.Stop(name)
	local at = TBMap.Probe.open[name]
	if not at then return end

	TBMap.Probe.open[name] = nil
	TBMap.Probe.times[name] = (TBMap.Probe.times[name] or 0) + (os.clock() - at)
end

function TBMap.Probe.Clear()
	TBMap.Probe.times = {}
	TBMap.Probe.open = {}
	TBMap.Probe.worst = {}
end

function TBMap.Probe.Report()
	local times = TBMap.Probe.times
	local names = {}

	for name in pairs(times) do names[#names + 1] = name end
	table.sort(names, function(a, b) return times[a] > times[b] end)

	for _, name in ipairs(names) do
		if times[name] >= 0.001 then
			print(string.format("[tbmap]   probe %-16s %7.3f s", name, times[name]))
		end
	end

	local worstNames = {}

	for name in pairs(TBMap.Probe.worst) do worstNames[#worstNames + 1] = name end
	table.sort(worstNames)

	for _, name in ipairs(worstNames) do
		local entry = TBMap.Probe.worst[name]

		print(string.format("[tbmap]   worst %-16s %7.3f s  (%s)", name, entry.seconds, entry.detail or ""))
	end
end
