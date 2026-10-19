local function get_password()
	local secret_file = io.open("/run/secrets/imap_pass_secret", "r")
	if secret_file then
		-- Read password stripping newlines
		local pass = secret_file:read("*a"):gsub("%s+", "")
		secret_file:close()
		return pass
	end
	return os.getenv("IMAP_PASS")
end

local server = os.getenv("IMAP_SERVER")
local port = tonumber(os.getenv("IMAP_PORT") or "993")
local user = os.getenv("IMAP_USER")
local pass = get_password()
local home_dir = os.getenv("HOME")
local data_dir = os.getenv("DATA_DIR") or (home_dir .. "/data")
local inbox_name = os.getenv("IMAP_INBOX_FOLDER") or "INBOX"
local junk_name = os.getenv("IMAP_JUNK_FOLDER") or "Junk"

if not server or not user or not pass then
	error("IMAP_SERVER, IMAP_USER and IMAP_PASS environment variables must be set.")
end

-- Operational Tuning
local BATCH_SIZE   = 25
local MAX_RETRIES  = 3
local RETRY_DELAY  = 6

options.timeout   = 60
options.subscribe = true

---------------
-- CONNECTION & RETRY ENGINE
---------------

local account = nil
local inbox   = nil
local junk    = nil

local function connect()
	local ok, acc = pcall(IMAP, {
		server   = server,
		port     = port,
		username = user,
		password = pass,
		ssl      = 'tls1.3'
	})

	if not ok or not acc then
		return false, tostring(acc)
	end

	local in_box = acc[inbox_name]
	local j_box  = acc[junk_name]

	if not in_box or not j_box then
		return false, "Could not locate required mailboxes: " .. inbox_name .. " or " .. junk_name
	end

	account = acc
	inbox   = in_box
	junk    = j_box
	return true, nil
end

local function with_retry(op_name, fn)
	for attempt = 1, MAX_RETRIES do
		local ok, res = pcall(fn)
		if ok and res ~= nil and res ~= false then
			return true, res
		end

		local err_msg = tostring(res)
		io.stderr:write(string.format("[!] %s failed (attempt %d/%d): %s\n", op_name, attempt, MAX_RETRIES, err_msg))

		if attempt < MAX_RETRIES then
			print(string.format("[*] Reconnecting in %d seconds...", RETRY_DELAY))
			os.execute("sleep " .. RETRY_DELAY)

			local recon_ok, recon_err = connect()
			if not recon_ok then
				io.stderr:write("[!] Reconnection failed: " .. tostring(recon_err) .. "\n")
			else
				print("[*] Reconnected successfully.")
			end
		end
	end
	return false, nil
end

---------------
-- EXECUTION PIPELINE
---------------

-- 1. Initial Connection
local connected, conn_err = connect()
if not connected then
	io.stderr:write("[!] Fatal: Initial connection failed: " .. tostring(conn_err) .. "\n")
	os.exit(1)
end

-- 2. Query Unseen Messages (with retry)
local search_ok, messages = with_retry("Search unseen messages", function()
	return inbox:is_unseen()
end)

if not search_ok or not messages or #messages == 0 then
	print("[+] INBOX has no unread messages. Nothing to do.")
	os.exit(0)
end

local total_messages = #messages
print(string.format("[+] Found %d unread message(s). Processing in chunks of %d...\n", total_messages, BATCH_SIZE))

local total_spam_moved = 0
local processed_count  = 0

-- 3. Iterative Chunk Pipeline
for i = 1, total_messages, BATCH_SIZE do
	local chunk_uids = {}
	for j = i, math.min(i + BATCH_SIZE - 1, total_messages) do
		table.insert(chunk_uids, messages[j])
	end

	local chunk_start = i
	local chunk_end   = i + #chunk_uids - 1
	print(string.format("=== Chunk [%d - %d of %d] ===", chunk_start, chunk_end, total_messages))

	-- Step A: Fetch chunk message bodies (with retry)
	local fetch_ok, fetched = with_retry(string.format("Fetch bodies [%d-%d]", chunk_start, chunk_end), function()
		local data = inbox:fetch_message(chunk_uids)
		if type(data) ~= "table" then
			error("fetch_message returned invalid response (not a table)")
		end
		return data
	end)

	if not fetch_ok then
		io.stderr:write("[!] Persistent fetch failure. Exiting cleanly to resume on next timer cycle.\n")
		os.exit(1)
	end

	-- Step B: Local Bogofilter Classification
	local chunk_spam = {}

	for idx, msg_obj in ipairs(chunk_uids) do
		processed_count = processed_count + 1
		local _, actual_uid = unpack(msg_obj)

		-- Match message body by chunk index or UID key
		local msg_str = fetched[idx] or fetched[actual_uid] or fetched[tostring(actual_uid)]

		if msg_str and type(msg_str) == "string" then
			local status = pipe_to('bogofilter -e -d ' .. data_dir, msg_str)

			if status == 0 then
				table.insert(chunk_spam, msg_obj)
			end
		end
	end

	-- Step C: Batch Move Spam in Chunk (with retry)
	if #chunk_spam > 0 then
		print(string.format("  [+] Moving %d spam message(s) to %s...", #chunk_spam, junk_name))

		local move_ok = with_retry(string.format("Move spam [%d-%d]", chunk_start, chunk_end), function()
			inbox:move_messages(junk, chunk_spam)
			return true
		end)

		if not move_ok then
			io.stderr:write("[!] Persistent move failure. Exiting to avoid duplicate state.\n")
			os.exit(1)
		end

		total_spam_moved = total_spam_moved + #chunk_spam
	else
		print("  [+] No spam detected in this chunk.")
	end

	print("")
end

print(string.format("[+] Finished run. Evaluated: %d | Spam Moved: %d", total_messages, total_spam_moved))
