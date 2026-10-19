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

account = IMAP {
	server = server,
	port = port,
	username = user,
	password = pass,
	ssl = 'tls1.3'
}

-- Target Folders
local inbox = account[inbox_name]
local junk = account[junk_name]

if not inbox then
	error("Fatal: Unable to locate IMAP mailbox: " .. inbox_name)
end
if not junk then
	error("Fatal: Unable to locate IMAP mailbox: " .. junk_name)
end

-- Fetch unread messages
local messages = inbox:is_unseen()

-- Array to accumulate spam UIDs for a single batch operation
local spam_messages = {}

for _, message in ipairs(messages) do
	local header_and_body = inbox:fetch_message({message})
	local _, msg_str = next(header_and_body)

	if msg_str and type(msg_str) == "string" then
		-- Pipe email content through bogofilter
		-- Returns 0 if spam, 1 if ham, 2 if unsure
		local status = pipe_to('bogofilter -e -d ' .. data_dir, msg_str)

		if status == 0 then
			-- Collect message UID for batch processing
			table.insert(spam_messages, message)
		end
	end
end

-- Perform a single batch move and mark-as-seen if spam was detected
if #spam_messages > 0 then
	print(string.format("[+] Batch moving %d spam message(s) to %s...", #spam_messages, junk_name))
	inbox:move_messages(junk, spam_messages)
end
