--  This script will take the scrollback, search for urls and present floating
--  pane and via fzf you'll pick the url you want. You can either open it via
--  your OS or copy it.
--
--  usage:
--  Include the script:
--  require("url-picker").setup()
--
--  Then set a binding for it:
--  rex.bind("ctrl+space>u", "url_pick")
--

local module = {}

local terminal_creator = "com.superlogical.terminal"
local chunk_bytes = 983040
local url_chars = "[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"
-- Schemes the picker offers. Opening hands the URL to the OS, so keep this to schemes worth opening.
local schemes = { http = true, https = true, file = true, ftp = true, sftp = true, ssh = true }
-- Rex runs gopher-lua, which lacks %f, so extract_urls checks word boundaries itself.
local patterns = {
	"[%a][%w%+%.%-]*://" .. url_chars,
	"mailto:" .. url_chars,
	-- scp-style git remotes, as printed by git remote -v and git clone.
	"git@[%w%-]+%.[%w%.%-]+:[%w%-%._~/]+",
}
local closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function read_scrollback(block_id)
	local res, err = rex.block.call(terminal_creator, "format", {
		block_id = block_id,
		unwrap = true,
		trim = true,
		max_bytes = chunk_bytes,
	})
	if err ~= nil then
		return nil, err
	end
	local parts = { res.content }
	local offset = #res.content
	-- A reply with id means more output remains; read the rest in parts.
	while res.id ~= nil do
		res, err = rex.block.call(terminal_creator, "blob_read", {
			block_id = block_id,
			id = res.id,
			offset = offset,
			max_bytes = chunk_bytes,
		})
		if err ~= nil then
			return nil, err
		end
		if res.content == nil or res.content == "" then
			break
		end
		table.insert(parts, res.content)
		offset = offset + #res.content
		if res.eof then
			break
		end
	end
	return table.concat(parts)
end

local function count(s, char)
	local _, n = s:gsub("%" .. char, "")
	return n
end

-- Drop trailing punctuation that usually ends a sentence rather than the URL.
-- A closing bracket stays when the URL opened it, as in Wikipedia links.
local function trim_url(url)
	while true do
		local last = url:sub(-1)
		local opener = closers[last]
		if last:match("[%.,;:!%?'\"]") then
			url = url:sub(1, -2)
		elseif opener and count(url, last) > count(url, opener) then
			url = url:sub(1, -2)
		else
			return url
		end
	end
end

local function accepted(url)
	local scheme = url:match("^([%a][%w%+%.%-]*)://.")
	if scheme then
		return schemes[scheme:lower()] == true
	end
	return url:match("^mailto:.") ~= nil or url:match("^git@[^:]+:.") ~= nil
end

-- What enter opens: scp-style git remotes become their web page; everything else opens as is.
local function open_target(url)
	local host, path = url:match("^git@([^:]+):(.+)$")
	if host then
		return "https://" .. host .. "/" .. path:gsub("%.git$", "")
	end
	return url
end

-- Matches newest first as { url, target }, each kept only at its newest occurrence.
local function extract_urls(text)
	local found = {}
	for _, pattern in ipairs(patterns) do
		local init = 1
		while true do
			local s, e = text:find(pattern, init)
			if not s then
				break
			end
			-- Skip matches glued to a word, like the mailto: in xmailto:.
			if s == 1 or not text:sub(s - 1, s - 1):match("[%w_]") then
				table.insert(found, { s = s, e = e })
			end
			init = e + 1
		end
	end
	table.sort(found, function(a, b)
		return a.s < b.s
	end)
	-- Patterns can overlap, as git@host:22/x inside ssh://git@host:22/x; keep the outer match.
	local urls, last_end = {}, 0
	for _, m in ipairs(found) do
		if m.s > last_end then
			last_end = m.e
			local url = trim_url(text:sub(m.s, m.e))
			if accepted(url) then
				table.insert(urls, url)
			end
		end
	end
	local result, seen = {}, {}
	for i = #urls, 1, -1 do
		local url = urls[i]
		if not seen[url] then
			seen[url] = true
			table.insert(result, { url, open_target(url) })
		end
	end
	return result
end

-- $1 is "open" or "copy", what enter does; the URLs follow as arguments, so nothing is written to disk.
-- Each argument is "url<tab>target": the list shows and copies the url, enter opens the target.
-- Copying writes OSC 52 to the pane, so the text reaches the clipboard of the app the user is in,
-- even when the server runs on another machine.
-- fzf exits non-zero on esc; exit 0 so Rex doesn't keep the pane open as a failure.
local picker_script = [[
mode=$1
shift
export URL_PICKER_COPY='printf "\033]52;c;%s\007" "$(printf %s "$1" | base64 | tr -d "\n")" > /dev/tty'
copy='become(sh -c "$URL_PICKER_COPY" sh {1})'
# Linux may have an unrelated open (openvt), so pick the opener by OS, not by what's on PATH.
case $(uname) in
Darwin) opener=open ;;
*) opener='nohup xdg-open' ;; # the browser it starts must outlive the pane
esac
if [ "$mode" = open ]; then
	enter="become($opener {2} >/dev/null 2>&1)"
	header='enter: open  ctrl-y: copy  esc: cancel'
else
	enter=$copy
	header='enter: copy  esc: cancel'
fi
printf '%s\n' "$@" | fzf \
	--tiebreak=index \
	--delimiter='\t' --with-nth=1 \
	--border=rounded --border-label=' URLs ' \
	--header="$header" \
	--with-shell='/bin/sh -c' \
	--bind="enter:$enter" \
	--bind="ctrl-y:$copy"
exit 0
]]

-- Open URLs only when the app that ran the action is on the server's machine.
-- Anything else, including an app Rex can't identify, copies instead.
local function client_is_local(ctx)
	if not ctx.client_id then
		return false
	end
	local res, err = rex.session.list_clients({})
	if err ~= nil or res == nil then
		return false
	end
	for _, client in ipairs(res.clients or {}) do
		if client.client_id == ctx.client_id then
			return client.principal ~= nil and client.principal.transport == "unix"
		end
	end
	return false
end

local function pick(ctx)
	if not ctx.block_id then
		error("No focused pane", 0)
	end
	local text, err = read_scrollback(ctx.block_id)
	if err ~= nil then
		error(err, 0)
	end
	local urls = extract_urls(text)
	if #urls == 0 then
		error("No URLs in this pane", 0)
	end

	local mode = client_is_local(ctx) and "open" or "copy"
	local command = { "/bin/sh", "-c", picker_script, "sh", mode }
	for _, url in ipairs(urls) do
		table.insert(command, url[1] .. "\t" .. url[2])
	end

	local _, layer_err = rex.session.new_layer({
		bounds = { 0.1, 0.3, 0.8, 0.4 },
		focus = true,
		layout = rex.layout.block({
			flavor = "com.superlogical.terminal.shell",
			options = {
				shell = "none",
				command = command,
				path_prepend = { "/opt/homebrew/bin", "/usr/local/bin" },
			},
		}),
	})
	if layer_err ~= nil then
		error(layer_err, 0)
	end
end

function module.setup()
	rex.action({
		name = "url_pick",
		title = "Pick URL",
		description = "Open or copy a URL from this pane's scrollback.",
		keywords = "link url open copy scrollback fzf mailto ssh git",
		run = pick,
	})
end

return module
