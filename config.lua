-- imap-spam-filter: config.lua
-- IMAPFilter configuration for Bogofilter spam classification and training

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

local function parse_header_field(hdr, field)
	if not hdr or type(hdr) ~= "string" then return nil end
	local lower_hdr = "\n" .. hdr:lower()
	local target = "\n" .. field:lower() .. ":"
	local s, e = lower_hdr:find(target, 1, true)
	if not s then return nil end
	local rest = hdr:sub(e)
	local line = rest:match("^%s*([^\r\n]+)")
	return line
end

local function get_body_snippet(raw_msg, max_chars)
	if not raw_msg or type(raw_msg) ~= "string" then return "" end
	max_chars = max_chars or 400
	local _, e = raw_msg:find("\r?\n\r?\n")
	local body_part = ""
	if e then
		body_part = raw_msg:sub(e + 1)
	else
		body_part = raw_msg
	end
	body_part = body_part:gsub("^%s+", "")
	if #body_part > max_chars then
		body_part = body_part:sub(1, max_chars) .. "..."
	end
	return body_part
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
local filter_mode    = (os.getenv("FILTER_MODE") or "filter"):lower()
local batch_size     = get_env_int("BATCH_SIZE", 25)
local max_retries    = get_env_int("MAX_RETRIES", 3)
local retry_delay    = get_env_int("RETRY_DELAY", 5)
local max_msg_size   = get_env_int("MAX_MSG_SIZE", 1048576) -- 1MB
local train_max      = get_env_int("TRAIN_MAX_MESSAGES", 100)
local live_train_max = get_env_int("LIVE_TRAIN_MAX", 0)
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
	return false, nil
end

-- Establish initial connection
local connected, conn_err = connect()
if not connected then
	io.stderr:write("[!] Fatal: Initial connection failed: " .. tostring(conn_err) .. "\n")
	os.exit(1)
end

---------------
-- MODE: TRAINING
---------------
if filter_mode == "train" then
	print("=== Starting Bogofilter Training Mode ===")
	print(string.format("Data directory: %s", data_dir))
	print(string.format("Training limit: up to %d messages per folder", train_max))

	-- 1. Train SPAM from Junk folder
	print(string.format("\n[*] Fetching messages from Junk mailbox '%s'...", junk_name))
	local junk_ok, junk_msgs = with_retry("Query Junk messages", function()
		return junk:select_all()
	end)

	local spam_trained = 0
	if junk_ok and junk_msgs and #junk_msgs > 0 then
		local total_junk = #junk_msgs
		local start_idx = math.max(1, total_junk - train_max + 1)
		print(string.format("[+] Found %d message(s) in Junk. Training on the latest %d...", total_junk, (total_junk - start_idx + 1)))

		for i = start_idx, total_junk do
			local msg_obj = junk_msgs[i]
			local actual_uid = msg_obj[2]

			local body_ok, body = with_retry("Fetch spam UID " .. tostring(actual_uid), function()
				msg_obj[1] = junk
				local res = junk:fetch_message({ msg_obj })
				return (res and res[actual_uid]) or false
			end)

			if body_ok and body and type(body) == "string" then
				local train_status = pipe_to(string.format("bogofilter -s -d %q", data_dir), body)
				if train_status == 0 then
					spam_trained = spam_trained + 1
				else
					io.stderr:write(string.format("[!] Failed to train spam UID %s (code %s)\n", tostring(actual_uid), tostring(train_status)))
				end
			end
		end
		print(string.format("[+] Successfully trained %d spam message(s).", spam_trained))
	else
		print("[+] No messages found in Junk to train as spam.")
	end

	-- 2. Train HAM from INBOX seen messages
	print(string.format("\n[*] Fetching read/seen messages from Inbox '%s'...", inbox_name))
	local ham_ok, ham_msgs = with_retry("Query seen INBOX messages", function()
		return inbox:is_seen()
	end)

	local ham_trained = 0
	if ham_ok and ham_msgs and #ham_msgs > 0 then
		local total_ham = #ham_msgs
		local start_idx = math.max(1, total_ham - train_max + 1)
		print(string.format("[+] Found %d seen message(s) in INBOX. Training on the latest %d...", total_ham, (total_ham - start_idx + 1)))

		for i = start_idx, total_ham do
			local msg_obj = ham_msgs[i]
			local actual_uid = msg_obj[2]

			local body_ok, body = with_retry("Fetch ham UID " .. tostring(actual_uid), function()
				msg_obj[1] = inbox
				local res = inbox:fetch_message({ msg_obj })
				return (res and res[actual_uid]) or false
			end)

			if body_ok and body and type(body) == "string" then
				local train_status = pipe_to(string.format("bogofilter -n -d %q", data_dir), body)
				if train_status == 0 then
					ham_trained = ham_trained + 1
				else
					io.stderr:write(string.format("[!] Failed to train ham UID %s (code %s)\n", tostring(actual_uid), tostring(train_status)))
				end
			end
		end
		print(string.format("[+] Successfully trained %d ham message(s).", ham_trained))
	else
		print("[+] No seen messages found in INBOX to train as ham.")
	end

	print(string.format("\n[+] Training complete: %d spam, %d ham trained.", spam_trained, ham_trained))
	os.exit(0)
end

---------------------------
-- MODE: LIVE TRAINING (Interactive)
---------------------------
if filter_mode == "live-train" or filter_mode == "interactive" then
	print("=== Starting Interactive Bogofilter Live Training ===")
	print(string.format("Data directory: %s", data_dir))
	if live_train_max > 0 then
		print(string.format("Review limit: up to %d message(s)", live_train_max))
	else
		print("Review limit: Unlimited (interactive until 'q')")
	end

	-- 1. Query read/seen status for status tags
	local seen_ok, seen_msgs = with_retry("Query seen INBOX messages", function()
		return inbox:is_seen()
	end)
	local seen_set = {}
	if seen_ok and seen_msgs then
		for _, m in ipairs(seen_msgs) do
			seen_set[m[2]] = true
		end
	end

	-- 2. Query all messages from INBOX
	print(string.format("[*] Fetching all messages from Inbox '%s'...", inbox_name))
	local all_ok, all_msgs = with_retry("Query all INBOX messages", function()
		return inbox:select_all()
	end)

	if not all_ok or not all_msgs or #all_msgs == 0 then
		print("[+] No messages found in INBOX to review.")
		os.exit(0)
	end

	local total_inbox = #all_msgs
	print(string.format("[+] Found %d message(s) in INBOX. Presenting from newest to oldest...\n", total_inbox))

	local reviewed = 0
	local trained_spam = 0
	local trained_ham = 0
	local skipped = 0
	local quit_requested = false

	for i = total_inbox, 1, -1 do
		if live_train_max > 0 and reviewed >= live_train_max then
			print(string.format("\n[*] Reached review limit of %d message(s).", live_train_max))
			break
		end

		local msg_obj = all_msgs[i]
		local actual_uid = msg_obj[2]
		local is_seen = (seen_set[actual_uid] == true)
		local status_tag = is_seen and "READ" or "UNREAD"

		-- Fetch header
		local header_ok, header = with_retry("Fetch header UID " .. tostring(actual_uid), function()
			msg_obj[1] = inbox
			local res = inbox:fetch_header({ msg_obj })
			return (res and res[actual_uid]) or false
		end)

		-- Fetch message body
		local body_ok, body = with_retry("Fetch message UID " .. tostring(actual_uid), function()
			msg_obj[1] = inbox
			local res = inbox:fetch_message({ msg_obj })
			return (res and res[actual_uid]) or false
		end)

		if not body_ok or not body or type(body) ~= "string" then
			io.stderr:write(string.format("[!] Could not fetch body for message UID %s. Skipping.\n", tostring(actual_uid)))
		else
			local date_str = parse_header_field(header, "Date") or "Unknown"
			local from_str = parse_header_field(header, "From") or "Unknown"
			local subj_str = parse_header_field(header, "Subject") or "(No Subject)"

			-- Get current prediction without updating DB
			local pred_st = pipe_to(string.format("bogofilter -e -p -d %q", data_dir), body)
			local pred_str = (pred_st == 0 and "SPAM") or (pred_st == 1 and "HAM") or (pred_st == 2 and "UNSURE") or "UNTRAINED"

			local count_display = string.format("[%d%s]", reviewed + 1, (live_train_max > 0 and string.format("/%d", live_train_max)) or "")
			print(string.rep("=", 80))
			print(string.format("%s UID: %s | Status: %s | Bogofilter Prediction: %s", count_display, tostring(actual_uid), status_tag, pred_str))
			print(string.format("Date:    %s", date_str))
			print(string.format("From:    %s", from_str))
			print(string.format("Subject: %s", subj_str))
			print(string.rep("-", 80))
			print("Body Preview:")
			print(get_body_snippet(body, 350))
			print(string.rep("-", 80))

			while true do
				io.write("Classify -> [s]pam | [h]am | [k]kip | [v]iew full | [q]uit: ")
				io.flush()
				local line = io.read()
				if not line then
					print("\n[*] Input closed.")
					quit_requested = true
					break
				end

				local choice = line:gsub("^%s+", ""):gsub("%s+$", ""):lower()
				if choice == "s" or choice == "spam" then
					local train_st = pipe_to(string.format("bogofilter -s -d %q", data_dir), body)
					if train_st == 0 then
						print(string.format("[✓] Trained UID %s as SPAM in Bogofilter.", tostring(actual_uid)))
						local move_ok = with_retry("Move spam UID " .. tostring(actual_uid) .. " to Junk", function()
							msg_obj[1] = inbox
							inbox:move_messages(junk, { msg_obj })
							return true
						end)
						if move_ok then
							print("[✓] Moved message to Junk folder.")
						else
							io.stderr:write("[!] Warning: Failed to move message to Junk folder.\n")
						end
						trained_spam = trained_spam + 1
						reviewed = reviewed + 1
					else
						io.stderr:write(string.format("[!] Error: Bogofilter failed to train spam (exit code %s)\n", tostring(train_st)))
					end
					break
				elseif choice == "h" or choice == "ham" then
					local train_st = pipe_to(string.format("bogofilter -n -d %q", data_dir), body)
					if train_st == 0 then
						print(string.format("[✓] Trained UID %s as HAM in Bogofilter (retained in INBOX).", tostring(actual_uid)))
						trained_ham = trained_ham + 1
						reviewed = reviewed + 1
					else
						io.stderr:write(string.format("[!] Error: Bogofilter failed to train ham (exit code %s)\n", tostring(train_st)))
					end
					break
				elseif choice == "k" or choice == "skip" or choice == "" then
					print(string.format("[-] Skipped UID %s.", tostring(actual_uid)))
					skipped = skipped + 1
					reviewed = reviewed + 1
					break
				elseif choice == "v" or choice == "view" then
					print("\n--- Full Headers ---")
					print(header or "(No headers)")
					print("\n--- Extended Body Preview ---")
					print(get_body_snippet(body, 2000))
					print("-----------------------------\n")
				elseif choice == "q" or choice == "quit" then
					print("\n[*] Quitting live training...")
					quit_requested = true
					break
				else
					print("[!] Invalid choice. Enter 's' for Spam, 'h' for Ham, 'k' to Skip, 'v' to View, or 'q' to Quit.")
				end
			end
		end

		if quit_requested then
			break
		end
	end

	print("\n" .. string.rep("=", 80))
	print("=== Bogofilter Live Training Summary ===")
	print(string.format("Messages reviewed: %d", reviewed))
	print(string.format("Trained as SPAM:  %d", trained_spam))
	print(string.format("Trained as HAM:   %d", trained_ham))
	print(string.format("Skipped:          %d", skipped))
	print(string.rep("=", 80))

	local db_file = data_dir .. "/wordlist.db"
	local f = io.open(db_file, "r")
	if f then
		f:close()
		print("\n[+] Current Bogofilter Wordlist Statistics:")
		os.execute(string.format("bogoutil -w %q .MSG_COUNT", db_file))
	end
	os.exit(0)
end

---------------
-- MODE: FILTER (Standard Operation)
---------------

-- 1. Query Unseen Messages
local search_ok, messages = with_retry("Search unseen messages", function()
	return inbox:is_unseen()
end)

if not search_ok or not messages or #messages == 0 then
	print("[+] INBOX has no unread messages. Nothing to do.")
	os.exit(0)
end

local total_messages = #messages
print(string.format("[+] Found %d unread message(s). Processing in chunks of %d...\n", total_messages, batch_size))

local total_spam_moved = 0
local processed_count  = 0

-- Bogofilter classification return codes:
--   0 = SPAM
--   1 = HAM (clean)
--   2 = UNSURE
--  >=3 = ERROR
local bogo_cmd = string.format("bogofilter -d %q", data_dir)
if auto_update then
	bogo_cmd = bogo_cmd .. " -u"
end

-- 2. Process in batches
for i = 1, total_messages, batch_size do
	local chunk_msgs = {}
	for j = i, math.min(i + batch_size - 1, total_messages) do
		table.insert(chunk_msgs, messages[j])
	end

	local chunk_start = i
	local chunk_end   = i + #chunk_msgs - 1
	print(string.format("=== Chunk [%d - %d of %d] ===", chunk_start, chunk_end, total_messages))

	local chunk_spam = {}

	for _, msg_obj in ipairs(chunk_msgs) do
		processed_count = processed_count + 1
		local actual_uid = msg_obj[2]

		-- Fetch message content with retry and reconnect support
		local fetch_ok, msg_data = with_retry("Fetch content for UID " .. tostring(actual_uid), function()
			msg_obj[1] = inbox -- Guard against reconnected mailbox references
			local size_res = inbox:fetch_size({ msg_obj })
			local msg_size = (size_res and size_res[actual_uid]) or 0
			if msg_size > max_msg_size then
				print(string.format("  [*] Message UID %s is large (%d bytes). Fetching header only...", tostring(actual_uid), msg_size))
				local hdr_res = inbox:fetch_header({ msg_obj })
				return (hdr_res and hdr_res[actual_uid]) or false
			else
				local fetch_res = inbox:fetch_message({ msg_obj })
				return (fetch_res and fetch_res[actual_uid]) or false
			end
		end)

		if msg_data and type(msg_data) == "string" then
			local status = pipe_to(bogo_cmd, msg_data)

			if status == 0 then
				print(string.format("  [SPAM] UID %s flagged as spam.", tostring(actual_uid)))
				table.insert(chunk_spam, msg_obj)
			elseif status == 1 then
				print(string.format("  [HAM] UID %s verified as ham.", tostring(actual_uid)))
			elseif status == 2 then
				print(string.format("  [UNSURE] UID %s score is unsure (leaving in INBOX).", tostring(actual_uid)))
			else
				io.stderr:write(string.format("  [!] UID %s bogofilter error (exit code %s, leaving in INBOX)\n", tostring(actual_uid), tostring(status)))
			end
		else
			io.stderr:write(string.format("  [!] Could not fetch content for UID %s. Skipping.\n", tostring(actual_uid)))
		end
	end

	-- Move detected spam in this chunk
	if #chunk_spam > 0 then
		print(string.format("  [+] Moving %d spam message(s) to %s...", #chunk_spam, junk_name))

		local move_ok = with_retry(string.format("Move spam [%d-%d]", chunk_start, chunk_end), function()
			for _, m in ipairs(chunk_spam) do
				m[1] = inbox
			end
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
