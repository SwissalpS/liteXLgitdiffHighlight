-- mod-version:3
--[[
	gitdiff_highlight/init.lua
	Highlights changed lines, if file is in a git repository.
	- Also supports [minimap], if user has it installed and activated.
	- Can replace [gitstatus], at least to some extent:
		- [gitstatus] scans the entire tree while this plugin only acts on
			loaded/saved files
		- [gitstatus] does not detect changes in repositories in subdirectories
			that aren't registered as submodules
		- [gitstatus] shows inserts and deletes of entire project in status view
			while this plugin shows the changes of current file
	- Note: colouring the treeview will follow real directory path and not symlinks
	version: 20230705.1323 by SwissalpS
	original [gitdiff_highlight] by github.com/vincens2005
	original [gitstatus] by github.com/rxi ?
	license: MIT
--]]
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local gitdiff = require "plugins.gitdiff_highlight.gitdiff"

config.plugins.gitdiff_highlight = common.merge({
  use_status = true,
  use_treeview = false,
  -- The config specification used by the settings gui
  config_spec = {
    name = "Git Diff Highlight",
    {
      label = "Show Info in Status View",
      description = "You may not want this if you also use [gitstatus]."
					.. "\n(Relaunch needed)",
      path = "use_status",
      type = "toggle",
      default = true
    },
    {
      label = "Colour Items in Tree View",
      description = "You may not want this if you also use [gitstatus]."
					.. "\n(Relaunch needed)",
      path = "use_treeview",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.gitdiff_highlight)

-- vscode defaults
style.gitdiff_addition = style.gitdiff_addition or { common.color "#587c0c" }
style.gitdiff_modification = style.gitdiff_modification or { common.color "#0c7d9d" }
style.gitdiff_deletion = style.gitdiff_deletion or { common.color "#94151b" }

-- in case TreeView is being used, holds alternative item colours
local cached_color_for_item = {}

local function color_for_diff(diff)
	if diff == "addition" then
		return style.gitdiff_addition
	elseif diff == "modification" then
		return style.gitdiff_modification
	else
		return style.gitdiff_deletion
	end
end

style.gitdiff_width = style.gitdiff_width or 3

local last_doc_lines = 0

-- maximum size of git diff to read, multiplied by current filesize
config.plugins.gitdiff_highlight.max_diff_size = 2


local diffs = setmetatable({}, { __mode = "k" })

local function get_diff(doc)
	return diffs[doc] or { is_in_repo = false }
end

local function gitdiff_padding(dv)
	return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end

local function update_diff(doc)
	if doc == nil or doc.filename == nil then return end

	local finfo = system.get_file_info(doc.filename)
	local full_path = finfo and system.absolute_path(doc.filename)
	if not full_path then
		return
	end

	core.log_quiet("[gitdiff_highlight] updating diff for " .. full_path)

	local path = full_path:match("(.*" .. PATHSEP .. ")")

	if not get_diff(doc).is_in_repo then
		local git_proc = process.start({
			"git", "-C", path, "ls-files", "--error-unmatch", full_path
		})
		while git_proc:running() do
			coroutine.yield(0.1)
		end
		if 0 ~= git_proc:returncode() then
			core.log_quiet("[gitdiff_highlight] file "
					.. full_path .. " is not in a git repository")

			return
		end
	end

	local max_diff_size
	max_diff_size = config.plugins.gitdiff_highlight.max_diff_size * finfo.size
	local diff_proc = process.start({
		"git", "-C", path, "diff", "HEAD", "--word-diff",
		"--unified=1", "--no-color", full_path
	})
	while diff_proc:running() do
		coroutine.yield(0.1)
	end
	diffs[doc] = gitdiff.changed_lines(diff_proc:read_stdout(max_diff_size))
	-- get branch name
	local branch_proc = process.start({
		"git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"
	})
	while branch_proc:running() do
		coroutine.yield(0.1)
	end
  diffs[doc].branch = (branch_proc:read_stdout() or ""):match("[^\n]*")
	-- get insert/delete statistics
	local inserts, deletes = 0, 0
  local nums_proc = process.start({
		"git", "-C", path, "diff", "--numstat"
  })
	while nums_proc:running() do
		coroutine.yield(0.1)
	end
	local numstat = nums_proc:read_stdout() or ""
	local ins, dels, p, abs_path
	for line in string.gmatch(numstat, "[^\n]+") do
		ins, dels, p = line:match("(%d+)%s+(%d+)%s+(.+)")
		-- not a 100% fool-proof check if this stat is about this file,
		-- should be good enough though
		if p and full_path:match(p .. "$") then
			inserts = inserts + (tonumber(ins) or 0)
			deletes = deletes + (tonumber(dels) or 0)
			if 0 == inserts and 0 == deletes then
				cached_color_for_item[full_path] = nil
				-- since this plugin avoids scanning entire trees,
				-- we can't reliably check if we can clear treeview colours for
				-- parent folders. We could scan cached_color_for_item to check on
				-- neighbour files that have been opened, but at this time SwissalpS
				-- doesn't consider that good enough and not worth the effort. Time
				-- would be better spent to implement a way to scan the entire tree like
				-- [gitstatus] does, but also find repos in subdirectories.
			else
				abs_path = full_path
				-- Color this file, and each parent folder. Too simple to not do it.
				while abs_path do
					cached_color_for_item[abs_path] = style.gitdiff_modification
					abs_path = common.dirname(abs_path)
				end
			end
		end
	end
	diffs[doc].inserts = inserts
	diffs[doc].deletes = deletes
	diffs[doc].is_in_repo = true
end

local old_docview_gutter = DocView.draw_line_gutter
local old_gutter_width = DocView.get_gutter_width
function DocView:draw_line_gutter(line, x, y, width)
	if not get_diff(self.doc).is_in_repo then
		return old_docview_gutter(self, line, x, y, width)
	end
	local lh = self:get_line_height()

	local gw, gpad = old_gutter_width(self)

	old_docview_gutter(self, line, x, y, gpad and gw - gpad or gw)

	if diffs[self.doc][line] == nil then
		return
	end

	local color = color_for_diff(diffs[self.doc][line])

	-- add margin in between highlight and text
	x = x + gitdiff_padding(self)

	local yoffset = self:get_line_text_y_offset()
	if diffs[self.doc][line] ~= "deletion" then
		renderer.draw_rect(x, y + yoffset, style.gitdiff_width,
				self:get_line_height(), color)

		return
	end
	renderer.draw_rect(x - style.gitdiff_width * 2,
			y + yoffset, style.gitdiff_width * 4, 2, color)

	return lh
end

function DocView:get_gutter_width()
	if not get_diff(self.doc).is_in_repo then return old_gutter_width(self) end
	return old_gutter_width(self) + style.padding.x * style.gitdiff_width / 12
end

local old_text_change = Doc.on_text_change
function Doc:on_text_change(type)
	local line
	if not get_diff(self).is_in_repo then goto end_of_function end
	line = self:get_selection()
	if diffs[self][line] == "addition" then goto end_of_function end
	-- TODO figure out how to detect an addition
	if type == "insert" or (type == "remove" and #self.lines == last_doc_lines) then
		diffs[self][line] = "modification"
	elseif type == "remove" then
		diffs[self][line] = "deletion"
	end
	::end_of_function::
	last_doc_lines = #self.lines
	return old_text_change(self, type)
end


local old_doc_save = Doc.save
function Doc:save(...)
	old_doc_save(self, ...)
	core.add_thread(function()
		update_diff(self)
	end)
end

local old_docview_new = DocView.new
function DocView:new(...)
	old_docview_new(self, ...)
	core.add_thread(function()
		update_diff(self.doc)
	end)
end

local old_doc_load = Doc.load
function Doc:load(...)
	old_doc_load(self, ...)
	core.add_thread(function()
		update_diff(self)
	end)
end

-- add status bar info after all plugins have loaded
core.add_thread(function()
	if not config.plugins.gitdiff_highlight.use_status
		or not core.status_view
	then return end

	local StatusView = require "core.statusview"
	core.status_view:add_item({
		name = "gitdiff_highlight:status",
		alignment = StatusView.Item.RIGHT,
		get_item = function()
			if not core.active_view:is(DocView) then return {} end

			local t = get_diff(core.active_view.doc)
			if not t.is_in_repo then return {} end

			return {
				(t.inserts ~= 0 or t.deletes ~= 0) and style.accent or style.text,
				t.branch,
				style.dim, "  ",
				t.inserts ~= 0 and style.accent or style.text, "+", t.inserts,
				style.dim, " / ",
				t.deletes ~= 0 and style.accent or style.text, "-", t.deletes,
			}
			--]]
		end,
		position = -1,
		tooltip = "branch and changes",
		separator = core.status_view.separator2
	})
end)

-- add treeview info after all plugins have loaded
core.add_thread(function()
	if not config.plugins.gitdiff_highlight.use_treeview
		or false == config.plugins.treeview
	then return end

	-- abort if TreeView isn't installed
	local found, TreeView = pcall(require, "plugins.treeview")
	if not found then return end

	local treeview_get_item_text = TreeView.get_item_text
	function TreeView:get_item_text(item, active, hovered)
		local text, font, color = treeview_get_item_text(self, item, active, hovered)
		if cached_color_for_item[item.abs_filename] then
			color = cached_color_for_item[item.abs_filename]
		end
		return text, font, color
	end
end)

-- add minimap support only after all plugins are loaded
core.add_thread(function()
	-- don't load minimap if user has disabled it
	if false == config.plugins.minimap then return end

	-- abort if MiniMap isn't installed
	local found, MiniMap = pcall(require, "plugins.minimap")
	if not found then return end


	-- Override MiniMap's line_highlight_color, but first
	-- stash the old one
	local old_line_highlight_color = MiniMap.line_highlight_color
	function MiniMap:line_highlight_color(line_index)
		local diff = get_diff(core.active_view.doc)
		if diff.is_in_repo and diff[line_index] then
			return color_for_diff(diff[line_index])
		end
		return old_line_highlight_color(line_index)
	end
end)

local function jump_to_next_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()
	if not get_diff(doc).is_in_repo then return end

	while diffs[doc][line] do
		line = line + 1
	end

	while line < #doc.lines do
		if diffs[doc][line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line + 1
	end
end

local function jump_to_previous_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()
	if not get_diff(doc).is_in_repo then return end

	while diffs[doc][line] do
		line = line - 1
	end

	while line > 0 do
		if diffs[doc][line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line - 1
	end
end

command.add("core.docview", {
	["gitdiff:previous-change"] = function()
		jump_to_previous_change()
	end,

	["gitdiff:next-change"] = function()
		jump_to_next_change()
	end,
})
