-- imap-spam-filter: config.lua
-- IMAPFilter configuration for Bogofilter spam classification

local function get_env_int(name, default)
	local val = os.getenv(name)
	if val and val ~= "" then
		local num = tonumber(val)
		if num then
			return num
		end
	end
	return default
end

local function get_password()
	local secret_file = io.open("/run/secrets/imap_pass_secret", "r")
	if secret_file then
		local pass = secret_file:read("*a"):gsub("[\r\n]+$", "")
		secret_file:close()
		return pass
	end
	return os.getenv("IMAP_PASS")
end

local server     = os.getenv("IMAP_SERVER")
local port       = get_env_int("IMAP_PORT", 993)
local user       = os.getenv("IMAP_USER")
local pass       = get_password()
local ssl_env    = (os.getenv("IMAP_SSL") or "auto"):lower()
local ssl_proto  = ssl_env
if ssl_env == "none" or ssl_env == "no" or ssl_env == "false" or ssl_env == "disabled" then
	ssl_proto = nil
end
local home_dir   = os.getenv("HOME") or "/home/imap-filter"
local data_dir   = os.getenv("DATA_DIR") or (home_dir .. "/data")
local inbox_name = os.getenv("IMAP_INBOX_FOLDER") or "INBOX"
local junk_name  = os.getenv("IMAP_JUNK_FOLDER") or "Junk"

if not server or not user or not pass then
	error("IMAP_SERVER, IMAP_USER and IMAP_PASS environment variables must be set.")
end

-- Operational Tuning
local batch_size     = get_env_int("BATCH_SIZE", 25)
local max_retries    = get_env_int("MAX_RETRIES", 3)
local retry_delay    = get_env_int("RETRY_DELAY", 5)
local max_msg_size   = get_env_int("MAX_MSG_SIZE", 1048576) -- 1MB
local auto_update    = os.getenv("BOGOFILTER_AUTO_UPDATE") == "true"

-- IMAP protocol options for connection stability
options.timeout   = 120
options.subscribe = true
options.limit     = 50
options.range     = 50

---------------
-- CONNECTION ENGINE
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
		ssl      = ssl_proto
	})

	if not ok or not acc then
		return false, tostring(acc)
	end

	local in_box = acc[inbox_name]
	local j_box  = acc[junk_name]

	if not in_box or not j_box then
		return false, "Could not locate required mailboxes: '" .. inbox_name .. "' or '" .. junk_name .. "'"
	end

	account = acc
	inbox   = in_box
	junk    = j_box
	return true, nil
end

local function with_retry(op_name, fn)
	for attempt = 1, max_retries do
		local ok, res = pcall(fn)
		if ok and res ~= nil and res ~= false then
			return true, res
		end

		local err_msg = tostring(res)
		io.stderr:write(string.format("[!] %s failed (attempt %d/%d): %s\n", op_name, attempt, max_retries, err_msg))

		if attempt < max_retries then
			print(string.format("[*] Reconnecting in %d seconds...", retry_delay))
			os.execute("sleep " .. retry_delay)

			local recon_ok, recon_err = connect()
		if not recon_ok then
				io.stderr:write("[!] Reconnection failed: " .. tostring(recon_err) .. "\n")
			else
				print("[*] Reconnected successfully.")
			end
		end
	end
	return false, string.format("Operation %s failed after %d retries.", op_name, max_retries)
end

local initial_ok, initial_err = connect()
if not initial_ok then
	error("Failed initial connection to IMAP server: " .. tostring(initial_err))
end

---------------
-- MODE: FILTER
---------------

local function is_spam(msg_obj)
	local cmd = string.format("bogofilter -e -p -d %q", data_dir)
	if auto_update then
		cmd = cmd .. " -u"
	end

	local status = msg_obj:pipe_to(cmd)
	if status == 0 then
		return true  -- 0 = Spam
	elseif status == 1 then
		return false -- 1 = Ham
	elseif status == 2 then
		io.stderr:write("[*] Bogofilter classified message as UNSURE.\n")
		return false
	else
		io.stderr:write(string.format("[!] Bogofilter returned non-standard exit code: %d\n", status))
		return false
	end
end

local fetch_ok, unseen_msgs = with_retry("select unseen messages", function()
	return inbox:is_unseen()
end)

if not fetch_ok or not unseen_msgs then
	io.stderr:write("[!] Aborting cycle: unable to retrieve unseen messages.\n")
	os.exit(1)
end

local total_messages = #unseen_msgs
if total_messages == 0 then
	print("[+] INBOX is clean. No unseen messages to filter.")
	os.exit(0)
end

print(string.format("[+] Found %d unseen message(s). Processing in chunks of %d...", total_messages, batch_size))

local total_spam_moved = 0
local chunk = {}

local function process_chunk(batch)
	if #batch == 0 then return end
	local spam_batch = {}

	for _, msg in ipairs(batch) do
		local check_ok, classified_spam = with_retry("classify message", function()
			local single_msg = { [1] = inbox, [2] = msg[2] }
			local size = single_msg[1]:fetch_size(single_msg[2])
			if size and size > max_msg_size then
				io.stderr:write(string.format("[*] Message %s exceeds %d bytes (%d bytes). Checking headers only.\n", tostring(single_msg[2]), max_msg_size, size))
				local hdr = single_msg[1]:fetch_header(single_msg[2])
				if hdr then
					local cmd = string.format("bogofilter -e -p -d %q", data_dir)
					local p = io.popen(cmd, "w")
					if p then
						p:write(hdr)
						local p_ok, _, exit_code = p:close()
						return (exit_code == 0)
					end
				end
				return false
			end
			return is_spam(single_msg)
		end)

		if check_ok and classified_spam then
			table.insert(spam_batch, msg)
		end
	end

	if #spam_batch > 0 then
		local move_ok, move_err = with_retry("move spam batch", function()
			spam_batch[1] = inbox
			return inbox:move_messages(junk, spam_batch)
		end)

		if move_ok then
			total_spam_moved = total_spam_moved + #spam_batch
			print(string.format("[+] Successfully moved %d spam message(s) to %s.", #spam_batch, junk_name))
		else
			io.stderr:write(string.format("[!] Failed to move spam batch: %s\n", tostring(move_err)))
		end
	end
end

for i, msg in ipairs(unseen_msgs) do
	table.insert(chunk, msg)
	if #chunk >= batch_size then
		process_chunk(chunk)
		chunk = {}
	end
end

if #chunk > 0 then
	process_chunk(chunk)
	chunk = {}
end

print(string.format("[+] Finished run. Evaluated: %d | Spam Moved: %d", total_messages, total_spam_moved))
