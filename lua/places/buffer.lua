local M = {
	-- Tree buffer id
	buf = nil,
	-- Tree buffer window
	win = nil,
	-- Line number <-> Place id lookup table
	line_ids = {},
	last_line = nil,
	updating = false,
	-- Prevent multiple autocmd registratrion for the tree buffer
	autocmd_buf = nil,

	previewing = false,
	-- ID of the previewed place
	preview_id = nil,
	-- Window to 'return' to after confirming/cancelling
	return_win = nil,
	-- Saved window state before previewing
	preview_restore = nil,
	-- Flag indicating that a temporary window was created for previewing
	committing = false,
}

-- {{{ Tree buffer creation/render

-- Check if the current buffer is the tree buffer
local function is_tree_buffer()
	return M.buf
		and vim.api.nvim_buf_is_valid(M.buf)
		and vim.api.nvim_get_current_buf() == M.buf
end

-- Ensure the tree buffer and window exist, return the buffer number and window id
local function ensure_window()
	if M.buf and vim.api.nvim_buf_is_valid(M.buf)
		and M.win and vim.api.nvim_win_is_valid(M.win)
	then
		return M.buf, M.win
	end

	if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
		M.buf = vim.api.nvim_create_buf(false, true)

		vim.bo[M.buf].buftype = "nofile"
		vim.bo[M.buf].bufhidden = "wipe"
		vim.bo[M.buf].swapfile = false
		vim.bo[M.buf].modifiable = false
		vim.bo[M.buf].readonly = true
		vim.bo[M.buf].filetype = "places_tree"
		vim.bo[M.buf].buflisted = false
	end

	vim.cmd("botright vsplit")
	M.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(M.win, M.buf)

	local width = math.min(math.floor(vim.o.columns * 0.2), 24)
	if width < 10 then width = 10 end

	vim.api.nvim_win_set_width(M.win, width)
	vim.wo[M.win].winfixwidth = true
	vim.wo[M.win].wrap = false
	vim.wo[M.win].cursorline = true
	vim.wo[M.win].number = false
	vim.wo[M.win].relativenumber = false
	vim.wo[M.win].signcolumn = "no"
	vim.wo[M.win].foldcolumn = "0"
	-- Must be disabled because virt_text_pos = "overlay" skips rendering of spaces, might fix it later, but it's required if we want to have 'invisible' buffer text for search to work properly
	vim.wo[M.win].cursorline = false

	return M.buf, M.win
end

-- Attach to the tree buffer when it's created
local function attach_tree_autocmds(buf)
	if M.autocmd_buf == buf then
		return
	end
	M.autocmd_buf = buf

	-- Change previewed entry upon line chanage
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = M.au_group,
		buffer = buf,
		callback = function()
			if M.updating or not is_tree_buffer() or M.committing then return end

			local line = vim.api.nvim_win_get_cursor(0)[1]
			if line == M.last_line then return end
			M.last_line = line

			local id = M.line_ids[line]
			if id then
				M.preview(id)
			end
		end,
	})

	-- Cancel previewing
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		group = M.au_group,
		buffer = buf,
		callback = function()
			if M.updating or M.committing then return end
			if M.previewing then
				M.cancel_preview()
			end
		end,
	})
end

-- Render rows into the tree buffer
local function render_rows(rows)
	local buf, win = ensure_window()
	buf = buf or 0
	attach_tree_autocmds(buf)

	M.updating = true
	M.line_ids = {}
	M.last_line = nil

	vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

	-- Build lines so the buffer is searchable
	local lines = {}
	---@diagnostic disable-next-line: unused-local
	for i, row in ipairs(rows) do
		local line = ""
		---@diagnostic disable-next-line: unused-local
		for j, component in ipairs(row.chunks) do
			line = line .. component[1]
		end
		lines[#lines + 1] = line
	end

	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].readonly = true
	vim.bo[buf].modifiable = false

	-- Extmarks
	for i, row in ipairs(rows) do
		M.line_ids[i] = row.id

		vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, 0, {
			virt_text = row.chunks,
			virt_text_pos = "overlay",
			hl_mode = "combine",
			priority = 200,
		})
	end


	local target_line = nil
	for i, id in ipairs(M.line_ids) do
		if id == M.state.current_id then
			target_line = i
			break
		end
	end

	if target_line and win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
		M.last_line = target_line
	end

	M.updating = false

	-- Preview the line under cursor when inside the tree buffer
	if vim.api.nvim_get_current_win() == win then
		M.preview_current()
	end
end

-- Referesh the tree buffer content, safe to call when the tree buffer is not visible
function M.refresh()
	if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)
			and M.win and vim.api.nvim_win_is_valid(M.win)) then
		return
	end

	render_rows(M.render.build_rows())
end

-- Open the tree buffer window
function M.open()
	local curwin = vim.api.nvim_get_current_win()

	if not (M.win
			and vim.api.nvim_win_is_valid(M.win)
			and curwin == M.win) then
		M.return_win = curwin
	end

	local buf, win = ensure_window()
	attach_tree_autocmds(buf)

	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	end

	render_rows(M.render.build_rows())
end

-- }}}

-- {{{ Preview

-- Check if there's a valid window to preview into
local function preview_win_is_valid()
	return M.return_win
		and vim.api.nvim_win_is_valid(M.return_win)
		and M.return_win ~= M.win
end

local function preview_to_place(place, win)
	if not (win and vim.api.nvim_win_is_valid(win) and place) then
		return
	end

	M.state.jumping = true

	local cur_buf = vim.api.nvim_win_get_buf(win)
	if place.bufnr ~= cur_buf then
		if vim.api.nvim_buf_is_valid(place.bufnr) and vim.api.nvim_buf_is_loaded(place.bufnr) then
			vim.api.nvim_win_set_buf(win, place.bufnr)
		else
			vim.api.nvim_win_call(win, function()
				vim.cmd("edit " .. vim.fn.fnameescape(place.filename))
			end)
		end
	end

	local new_buf = vim.api.nvim_win_get_buf(win)
	local lc = vim.api.nvim_buf_line_count(new_buf)
	local line = math.min(math.max(place.line or 1, 1), lc)
	local col = math.max(place.col or 0, 0)

	pcall(vim.api.nvim_win_set_cursor, win, { line, col })
	pcall(vim.api.nvim_win_call, win, function()
		vim.cmd("normal! zvzz")
	end)

	vim.schedule(function()
		M.state.jumping = false
	end)
end

-- Preview a place with a specific id
function M.preview(id)
	if not is_tree_buffer() then
		return
	end

	-- No preview window? Then do not preview.
	if not preview_win_is_valid() then
		return
	end

	local place = M.state.places and M.state.places[id]
	if not place then
		return
	end

	if not M.previewing then
		M.previewing = true

		if not (M.return_win and vim.api.nvim_win_is_valid(M.return_win)) then
			return nil
		end

		-- Save window buf/view before previewing
		M.preview_restore = {}
		vim.api.nvim_win_call(M.return_win, function()
			M.preview_restore.buf = vim.api.nvim_win_get_buf(M.return_win)
			M.preview_restore.view = vim.fn.winsaveview()
		end)
	end

	if M.preview_id == id then
		return
	end

	M.preview_id = id
	preview_to_place(place, M.return_win)
end

-- Preview the line under cursor
function M.preview_current()
	if not is_tree_buffer() then
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	local id = M.line_ids[line]
	if id then
		M.preview(id)
	end
end

-- Cancel preview (e.g when exiting)
function M.cancel_preview()
	if not M.previewing then
		return
	end

	-- Restore saved window state
	if preview_win_is_valid() then
		if not (M.return_win and vim.api.nvim_win_is_valid(M.return_win) and M.preview_restore) then
			return
		end

		M.state.jumping = true

		if M.preview_restore.buf and vim.api.nvim_buf_is_valid(M.preview_restore.buf) then
			vim.api.nvim_win_set_buf(M.return_win, M.preview_restore.buf)
		end

		if M.preview_restore.view then
			vim.api.nvim_win_call(M.return_win, function()
				pcall(vim.fn.winrestview, M.preview_restore.view)
			end)
		end

		vim.schedule(function()
			M.state.jumping = false
		end)
	end

	M.previewing = false
	M.preview_id = nil
	M.preview_restore = nil
end

-- Confirm preview, make the preview the new active buffer
function M.confirm()
	if not is_tree_buffer() then
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	local id = M.line_ids[line]
	if id then
		M.jump(id)
	end
end

-- }}}

-- {{{ Jumps

local function jump_to(place)
	M.state.jumping = true
	local cur_buf = vim.api.nvim_get_current_buf()

	if place.bufnr ~= cur_buf then
		if vim.api.nvim_buf_is_valid(place.bufnr) and vim.api.nvim_buf_is_loaded(place.bufnr) then
			vim.api.nvim_set_current_buf(place.bufnr)
		else
			vim.cmd("edit " .. vim.fn.fnameescape(place.filename))
		end
	end

	local lc = vim.api.nvim_buf_line_count(vim.api.nvim_get_current_buf())
	pcall(vim.api.nvim_win_set_cursor, 0, { math.min(place.line, lc), place.col })
	pcall(vim.cmd, "normal! zvzz")

	vim.schedule(function()
		M.state.jumping = false
	end)
end

function M.jump(id)
	local cur = M.state.places[id]
	if not cur then
		vim.notify("places: unknown id " .. tostring(id))
		return
	end

	local in_tree = is_tree_buffer()
	M.state.current_id = id

	if in_tree then
		-- Get the target window, either use the 'return_win', or create a new window on demand
		if not preview_win_is_valid() then
			if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
				vim.notify("places: Cannot find tree buffer", vim.log.levels.ERROR)
				return
			end

			-- Create a window only when the user confirms a selection
			vim.api.nvim_set_current_win(M.win)
			vim.cmd("leftabove vsplit")
			M.return_win = vim.api.nvim_get_current_win()

			-- Keep the tree window narrow and restore focus to it
			pcall(vim.api.nvim_win_set_width, M.win, math.min(math.floor(vim.o.columns * 0.2), 24))
			vim.api.nvim_set_current_win(M.win)
		end


		if M.return_win and vim.api.nvim_win_is_valid(M.return_win) then
			M.previewing = false
			M.preview_id = nil
			M.preview_restore = nil

			-- Move focus out of the tree and jump in the return window
			vim.api.nvim_set_current_win(M.return_win)
			jump_to(cur)
		end
	else
		jump_to(cur)
	end

	M.refresh()
end

-- }}}

function M.setup(state, render, ns, au_group)
	M.state = state
	M.render = render
	M.ns = ns
	M.au_group = au_group

	-- Update return_win so preview uses the last window
	vim.api.nvim_create_autocmd("WinEnter", {
		group = M.au_group,
		callback = function()
			local win = vim.api.nvim_get_current_win()

			-- Ignore tree window
			if M.win and win == M.win then return end

			local buf = vim.api.nvim_win_get_buf(win)
			local bt = vim.bo[buf].buftype
			if bt ~= "" then
				return
			end

			-- This is now the latest valid "return" window
			M.return_win = win
		end,
	})
end

return M
