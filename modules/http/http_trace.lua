local ffi = require('ffi')
local bit = require('bit')
local condition = require('cqueues.condition')

-- Buffer selected record information to a table
local function add_selected_records(dst, records)
	for _, rec in ipairs(records) do
		local rank = rec.rank
		-- Separate the referral chain verified flag
		local verified = bit.band(rec.rank, kres.rank.AUTH)
		if verified then
			rank = bit.band(rank, bit.bnot(kres.rank.AUTH))
		end
		local rank_name = kres.rank_tostring[rank] or tostring(rank)
		-- Write out each individual RR
		for rr in tostring(rec.rr):gmatch('[^\n]+\n?') do
			local row = string.format('cached: %s, rank: %s, record: %s',
				rec.cached, rank_name:lower(), rr)
			table.insert(dst, row)
		end
	end
end

local function format_selected_records(header, records)
	if #records == 0 then return '' end
	return string.format('%s\n%s\n', header, string.rep('-', #header))
	       .. table.concat(records, '') .. '\n'
end

-- Trace execution of DNS queries
local function serve_trace(h, _)
	local path = h:get(':path')
	local qname, qtype_str = path:match('/trace/([^/]+)/?([^/]*)')
	if not qname then
		return 400, 'expected /trace/<query name>/<query type>'
	end

	-- Parse query type (or default to A)
	if not qtype_str or #qtype_str == 0 then
		qtype_str = 'A'
	end

	local qtype = kres.type[qtype_str]
	if not qtype then
		return 400, string.format('unexpected query type: %s', qtype_str)
	end

	-- Create logging handler callback
	local buffer = {}
	local buffer_log_cb = ffi.cast('trace_log_f', function (query, source, msg)
		local message = string.format('[%5u] [%s] %s',
			tonumber(query.id), ffi.string(source), ffi.string(msg))
		table.insert(buffer, message)
	end)

	-- Wait for the result of the query
	-- Note: We can't do non-blocking write to stream directly from resolve callbacks
	-- because they don't run inside cqueue.
	local cond = condition.new()
	local done = false

	-- Resolve query and buffer logs into table
	local answers, authority = {}, {}
	resolve {
		name = qname,
		type = qtype,
		options = {'TRACE'},
		begin = function (req)
			req = kres.request_t(req)
			req.trace_log = buffer_log_cb
		end,
		finish = function (_, req)
			req = kres.request_t(req)
			add_selected_records(answers, req.answ_selected)
			add_selected_records(authority, req.auth_selected)
			cond:signal()
			done = true
		end
	}

	-- Wait for asynchronous query and free callbacks
	if done then
		cond:wait(0) -- Must pick up the signal
	else
		cond:wait()
	end
	buffer_log_cb:free()

	-- Build the result
	local result = table.concat(buffer, '') .. '\n'
	               .. format_selected_records('Used records from answer:', answers)
	               .. format_selected_records('Used records from authority:', authority)
	-- Return buffered data
	if not done then
		return 504, result
	end
	return result
end

-- Export endpoints
return {
	endpoints = {
		['/trace']   = {'text/plain', serve_trace},
	}
}