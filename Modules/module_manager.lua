local M = {}

local DIR = hs.configdir .. "/Modules"
local modules = {}
local enabled = {}
local window = nil
local bridge = nil
local visible = false
local hotkey = nil
local busy = {}
local escTap = nil

local function log(message)
    print("[ModuleManager] " .. tostring(message))
end

local function alert(message)
    hs.alert.show(tostring(message), 2)
end

local function esc(value)
    local s = tostring(value or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function discover()
    local found = {}
    local seen = {}
    local ok, iterator, state, initial = pcall(hs.fs.dir, DIR)

    if not ok or type(iterator) ~= "function" then
        log("Cannot read Modules directory: " .. tostring(iterator))
        modules = {}
        return
    end

    for file in iterator, state, initial do
        local name = file:match("^(.+)%.lua$")

        if name and name ~= "module_manager" and not seen[name] then
            seen[name] = true

            local path = DIR .. "/" .. file
            local key = "Modules." .. name
            local mod = package.loaded[key]
            local loaded, result = true, mod

            if type(mod) ~= "table" then
                loaded, result = pcall(require, key)
            end

            if loaded
                and type(result) == "table"
                and type(result.start) == "function"
                and type(result.stop) == "function" then

                result.id = name
                result.name = tostring(result.name or name)
                result.description = tostring(result.description or "No description")
                result.version = tostring(result.version or "1.0.0")
                result.hotkeys = type(result.hotkeys) == "table" and result.hotkeys or {}
                result.filePath = path

                found[#found + 1] = result
            else
                log("Invalid module [" .. name .. "]: " .. tostring(result))
            end
        end
    end

    table.sort(found, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    modules = found
end

local function runModuleFunction(mod, action)
    local fn = mod[action]

    if type(fn) ~= "function" then
        return false, "Missing " .. action .. "()"
    end

    local ok, result, detail = pcall(fn)

    if not ok then
        return false, result
    end

    if result == false then
        return false, detail or (action .. "() returned false")
    end

    return true
end

local function toggle(id)
    if busy[id] then
        return
    end

    local mod

    for _, item in ipairs(modules) do
        if item.id == id then
            mod = item
            break
        end
    end

    if not mod then
        alert("Module not found: " .. tostring(id))
        return
    end

    busy[id] = true

    local action = enabled[id] and "stop" or "start"
    local ok, err = runModuleFunction(mod, action)

    busy[id] = nil

    if not ok then
        log(action .. " failed for " .. mod.name .. ": " .. tostring(err))
        alert("Failed to " .. action .. " " .. mod.name)
        return
    end

    enabled[id] = action == "start" and true or nil

    log(mod.name .. (enabled[id] and " enabled" or " disabled"))

    if visible then
        M.refresh()
    end
end

local function buildHTML()
    local rows = {}
    local active = 0

    for _, mod in ipairs(modules) do
        local on = enabled[mod.id] == true

        if on then
            active = active + 1
        end

        local keys = {}

        for _, key in ipairs(mod.hotkeys) do
            keys[#keys + 1] = '<kbd>' .. esc(key) .. '</kbd>'
        end

        if #keys == 0 then
            keys[1] = '<span class="muted">No shortcuts</span>'
        end

        rows[#rows + 1] = string.format([[
<div class="module" data-search="%s">
  <div class="module-info">
    <div class="module-title">%s</div>
    <div class="description">%s</div>
    <div class="metadata">
      <span class="version">v%s</span>
      <span class="keys">%s</span>
    </div>
  </div>
  <button class="finder" onclick="send('reveal','%s')" title="Show in Finder" aria-label="Show in Finder">
    <svg viewBox="0 0 16 16"><path d="M14 2H9.5a.5.5 0 0 0 0 1h3.793L6.146 10.146a.5.5 0 0 0 .708.708L14 3.707V7.5a.5.5 0 0 0 1 0V2.5A.5.5 0 0 0 14 2z"/><path d="M12.5 9a.5.5 0 0 0-.5.5V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3.5a.5.5 0 0 0 0-1H3a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V9.5a.5.5 0 0 0-.5-.5z"/></svg>
  </button>
  <button class="switch %s" onclick="send('toggle','%s')" aria-label="Toggle module" aria-pressed="%s">
    <span></span>
  </button>
</div>
]],
            esc(mod.name .. " " .. mod.description .. " " .. mod.id),
            esc(mod.name),
            esc(mod.description),
            esc(mod.version),
            table.concat(keys, " "),
            esc(mod.id),
            on and "on" or "",
            esc(mod.id),
            on and "true" or "false"
        )
    end

    local content

    if #rows == 0 then
        content = [[
<div class="empty">
  <div class="empty-icon">⌘</div>
  <div class="empty-title">No modules found</div>
  <div class="empty-description">Add Lua modules to your Modules folder. Each module must return a table with start() and stop() functions.</div>
  <button class="primary" onclick="send('folder')">Open Modules Folder</button>
</div>
]]
    else
        content = table.concat(rows, "\n")
    end

    return [=[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<style>
:root {
  color-scheme: light dark;
  --bg: #f5f5f7;
  --surface: #ffffff;
  --text: #1d1d1f;
  --secondary: #86868b;
  --line: rgba(0,0,0,.09);
  --control: #f0f0f2;
  --accent: #007aff;
  --green: #34c759;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #202022;
    --surface: #29292c;
    --text: #f5f5f7;
    --secondary: #a1a1a6;
    --line: rgba(255,255,255,.10);
    --control: #343438;
    --accent: #0a84ff;
    --green: #30d158;
  }
}
* { box-sizing: border-box; }
html {
  background: transparent;
  border-radius: 16px;
  overflow: hidden;
}
body {
  width: 100%;
  height: 100vh;
  margin: 0;
  padding: 0;
  color: var(--text);
  background: var(--bg);
  font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border-radius: 16px;
  border: 1px solid var(--line);
}
button, input { font: inherit; }
button { -webkit-appearance: none; appearance: none; }
.searchbar {
  flex-shrink: 0;
  display: flex;
  gap: 9px;
  padding: 14px;
  border-bottom: 1px solid var(--line);
  background: var(--bg);
}
.search {
  flex: 1;
  min-width: 0;
  height: 32px;
  padding: 0 11px;
  color: var(--text);
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 8px;
  outline: none;
  font-size: 12px;
  user-select: text;
}
.search:focus { border-color: var(--accent); }
button.standard {
  height: 32px;
  padding: 0 13px;
  color: var(--text);
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 8px;
  cursor: pointer;
}
button.standard:hover { background: var(--control); }
button:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  background: var(--surface);
}
.module {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 78px;
  padding: 13px 15px;
  border-bottom: 1px solid var(--line);
  background: var(--surface);
}
.module:hover { background: var(--control); }
.module-info { flex: 1; min-width: 0; }
.module-title {
  font-size: 13px;
  font-weight: 600;
  line-height: 1.4;
}
.description {
  margin-top: 3px;
  color: var(--secondary);
  font-size: 11px;
  line-height: 1.4;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.metadata {
  display: flex;
  align-items: center;
  gap: 9px;
  margin-top: 7px;
}
.version {
  flex-shrink: 0;
  color: var(--secondary);
  font: 10px ui-monospace, SFMono-Regular, monospace;
}
.keys { display: flex; flex-wrap: wrap; gap: 4px; }
kbd {
  padding: 2px 5px;
  color: var(--secondary);
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 4px;
  font: 10px ui-monospace, SFMono-Regular, monospace;
}
.muted { color: var(--secondary); font-size: 10px; }
.finder {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  padding: 0;
  color: var(--secondary);
  background: transparent;
  border: 1px solid transparent;
  border-radius: 7px;
  cursor: pointer;
}
.finder:hover {
  color: var(--text);
  background: var(--bg);
  border-color: var(--line);
}
.finder svg {
  display: block;
  width: 16px;
  height: 16px;
  fill: currentColor;
}
.switch {
  position: relative;
  flex-shrink: 0;
  width: 38px;
  height: 22px;
  padding: 0;
  border: 0;
  border-radius: 20px;
  background: #b8b8bd;
  cursor: pointer;
  transition: background .16s ease;
}
@media (prefers-color-scheme: dark) {
  .switch { background: #55555a; }
}
.switch.on { background: var(--green); }
.switch span {
  position: absolute;
  top: 3px;
  left: 3px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0,0,0,.22);
  transition: transform .16s ease;
}
.switch.on span { transform: translateX(16px); }
.switch:disabled { opacity: .55; cursor: wait; }
.footer {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 10px 14px;
  background: var(--bg);
  border-top: 1px solid var(--line);
}
.footer-label { color: var(--secondary); font-size: 11px; }
.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 64px 28px;
  text-align: center;
}
.empty-icon { margin-bottom: 14px; font-size: 32px; color: var(--secondary); }
.empty-title { font-size: 15px; font-weight: 600; }
.empty-description {
  max-width: 290px;
  margin: 9px 0 18px;
  color: var(--secondary);
  font-size: 12px;
  line-height: 1.6;
}
.primary {
  padding: 9px 15px;
  color: white;
  background: var(--accent);
  border: 0;
  border-radius: 8px;
  cursor: pointer;
  font-weight: 500;
}
.primary:hover { opacity: .86; }
::-webkit-scrollbar { width: 8px; }
::-webkit-scrollbar-thumb {
  background: rgba(128,128,128,.35);
  border: 2px solid transparent;
  background-clip: padding-box;
  border-radius: 8px;
}
</style>
</head>
<body>
<div class="searchbar">
  <input class="search" id="search" placeholder="Search modules..." autocomplete="off" spellcheck="false">
  <button class="standard" onclick="send('refresh')">Refresh</button>
</div>
<div class="list" id="list">]=] .. content .. [=[</div>
<div class="footer">
  <span class="footer-label">]=] .. active .. " of " .. #modules .. [=[ modules active &bull; Esc to close</span>
  <button class="standard" onclick="send('folder')">Open Folder</button>
</div>
<script>
function send(action, id) {
  try {
    window.webkit.messageHandlers.moduleManagerBridge.postMessage(
      JSON.stringify({action: action, id: id || ''})
    );
  } catch (error) {
    console.error('Module manager bridge error:', error);
  }
}
const search = document.getElementById('search');
search.addEventListener('input', function() {
  const query = this.value.trim().toLowerCase();
  document.querySelectorAll('.module').forEach(function(el) {
    el.style.display = el.dataset.search.toLowerCase().includes(query) ? 'flex' : 'none';
  });
});
document.addEventListener('keydown', function(event) {
  if (event.key === 'Escape') send('close');
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'r') {
    event.preventDefault();
    send('refresh');
  }
});
</script>
</body>
</html>
]=]
end

function M.refresh()
    if not window then
        return
    end

    discover()

    local ok, err = pcall(function()
        window:html(buildHTML())
    end)

    if not ok then
        log("Render failed: " .. tostring(err))
    end
end

local function openFolder()
    local output, status = hs.execute(
        "/usr/bin/open " .. shellQuote(DIR),
        true
    )

    if not status then
        alert("Cannot open Modules folder")
    end
end

local function revealModule(id)
    for _, mod in ipairs(modules) do
        if mod.id == id then
            local output, status = hs.execute(
                "/usr/bin/open -R " .. shellQuote(mod.filePath),
                true
            )

            if not status then
                alert("Cannot reveal module in Finder")
            end

            return
        end
    end

    alert("Module file not found")
end

local function createWindow()
    local screen = hs.screen.mainScreen()

    if not screen then
        alert("No available screen")
        return false
    end

    local frame = screen:frame()
    local w = math.min(600, frame.w - 40)
    local h = math.min(500, frame.h - 60)

    bridge = hs.webview.usercontent.new("moduleManagerBridge")

    bridge:setCallback(function(message)
        local body = message and message.body
        local data

        if type(body) == "string" then
            local ok, result = pcall(hs.json.decode, body)

            if ok then
                data = result
            end
        elseif type(body) == "table" then
            data = body
        end

        if type(data) ~= "table" then
            return
        end

        if data.action == "toggle" then
            toggle(tostring(data.id or ""))
        elseif data.action == "refresh" then
            M.refresh()
        elseif data.action == "folder" then
            openFolder()
        elseif data.action == "reveal" then
            revealModule(tostring(data.id or ""))
        elseif data.action == "close" then
            M.stop()
        end
    end)

    local ok, result = pcall(function()
        return hs.webview.new({
            x = frame.x + (frame.w - w) / 2,
            y = frame.y + (frame.h - h) / 2,
            w = w,
            h = h
        }, {
            developerExtrasEnabled = false
        }, bridge)
    end)

    if not ok or not result then
        log("Window creation failed: " .. tostring(result))
        alert("Cannot create module manager window")
        bridge = nil
        return false
    end

    window = result

    window:windowStyle({"borderless"})
    window:transparent(true)

    window:allowTextEntry(true)
    window:closeOnEscape(true)
    window:level(hs.drawing.windowLevels.floating)
    window:shadow(true)

    window:windowCallback(function(action)
        if action == "closing" then
            visible = false
            window = nil
            bridge = nil
            if escTap then
                escTap:stop()
            end
        end
    end)

    return true
end

local function show()
    if not window then
        if not createWindow() then
            return
        end
    end

    M.refresh()

    local ok, err = pcall(function()
        window:show()
        window:bringToFront()
    end)

    if not ok then
        log("Show failed: " .. tostring(err))
        window = nil
        bridge = nil
        visible = false
        alert("Cannot show module manager")
        return
    end

    visible = true

    if not escTap then
        escTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
            if visible and e:getKeyCode() == 53 then
                M.stop()
                return true
            end
            return false
        end)
    end
    escTap:start()
end

function M.start()
    show()
end

function M.stop()
    visible = false

    if escTap then
        escTap:stop()
    end

    if window then
        local current = window
        window = nil
        bridge = nil

        pcall(function()
            current:hide()
        end)
    end
end

function M.toggle()
    if visible and window then
        M.stop()
    else
        show()
    end
end

hotkey = hs.hotkey.bind({"cmd", "alt"}, "M", M.toggle)

return M
