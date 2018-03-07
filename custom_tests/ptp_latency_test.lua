local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local stats  = require "stats"
local hist   = require "histogram"
local namespaces = require "namespaces"

local PKT_SIZE	= 3000
local ETH_DST	= "11:12:13:14:15:16"

local function getRstFile(...)
	local args = { ... }
	for i, v in ipairs(args) do
		result, count = string.gsub(v, "%-%-result%=", "")
		if (count == 1) then
			return i, result
		end
	end
	return nil, nil
end

function configure(parser)
	parser:description("Generates bidirectional CBR traffic with hardware rate control and measure latencies.")
	parser:argument("rx", "Device to receive from."):convert(tonumber)
	parser:argument("tx", "Device to transmit to."):convert(tonumber)
	parser:option("-m --maxrate", "Max transmission rate of the DUT in Mbit/s."):default(40000):convert(tonumber)
	parser:option("-l --load", "Max transmission rate of the DUT in Mbit/s."):default(10):convert(tonumber)
	parser:option("-s --framesize", "Frame size"):default(PKT_SIZE):convert(tonumber)
	parser:option("-f --file", "Filename of the latency histogram."):default("histogram.csv")
end

function master(args)
	if args.rx == args.tx then
		print("Two different devices are required for this test.")
		os.exit(1)
	end

	local rxdev = device.config({port = args.rx, rxQueues = 2, txQueues = 2})
	local txdev = device.config({port = args.tx, rxQueues = 2, txQueues = 2})
	device.waitForLinks()

	-- TODO grab all of this stuff from user supplied arguments
	local maxrate = args.maxrate
	local load = args.load
	local framesize = args.framesize
	local test_duration = 5

	local sharedspace = namespaces:get("sharedspace")

	local txrate = maxrate * load / 100
	print("Frame Size: " .. framesize .. ", Load: " .. load .. ", Tx Rate: " .. txrate)

	txdev:setRate(txrate)
	-- do we need to have an Rx function?
	-- mg.startTask("loadSlaveRx", rxdev, args.framesize)
	mg.startTask("loadSlaveTx", txdev, 0, framesize, test_duration)
	txdev.duration = test_duration

	print("Duration ".. tostring(txdev.duration))
	print("txdev ".. tostring(txdev))
	stats.startStatsTask{txdev, duration = test_duration}
	mg.startSharedTask("timerSlave", txdev:getTxQueue(1), rxdev:getRxQueue(1),
		tostring(framesize).."_"..tostring(load).."_"..tostring(i).."_"..args.file)
	mg.waitForTasks()

end

function loadSlaveTx(device, queue_id, frame_size, duration)
	local sharedspace = namespaces:get("sharedspace")
	sharedspace.tx_running = true
	local starttime = os.time()
	local endtime = os.time() + duration
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = txDev,
			ethDst = ETH_DST,
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray()
	while mg.running() and os.time() < endtime do
		bufs:alloc(frame_size)
		device:getTxQueue(queue_id):send(bufs)
	end
	device:getTxQueue(queue_id):stop()
	sharedspace.tx_running = false
end

function timerSlave(txQueue, rxQueue, histfile)
	local sharedspace = namespaces:get("sharedspace")
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	mg.sleepMillis(1000) -- ensure that the load task is running
	while sharedspace.tx_running do
		hist:update(timestamper:measureLatency(function(buf) buf:getEthernetPacket().eth.dst:setString(ETH_DST) end))
	end
	txQueue:stop()
	hist:print()
	hist:save(histfile)
end
