local M = {
}

M.buffer = {
	buf = nil,
	win = nil,
	line_ids = {},
	last_line = nil,
	updating = false,
	autocmd_buf = nil,

	-- preview/session state
	previewing = false,
	preview_id = nil,
	return_win = nil,
	preview_restore = nil,
	committing = false,
}

M.au_group = vim.api.nvim_create_augroup("PlacesAugroup", { clear = true })
M.ns = vim.api.nvim_create_namespace("PlacesNamespace")

function M.setup(opts)
	opts = opts or {}
	M.util = require("places.util")
	-- State
	M.state = require("places.state")
	M.state.setup()
	-- Render
	M.render = require("places.render")
	M.render.setup(M.state, opts.render)
	-- Buffer
	M.buffer = require("places.buffer")
	M.buffer.setup(M.state, M.render, M.ns, M.au_group)

	-- Register when entering into a buffer
	vim.api.nvim_create_autocmd("BufEnter", {
		group    = M.au_group,
		callback = function()
			if M.state.jumping then return end
			local buf = vim.api.nvim_get_current_buf()
			local pos = vim.api.nvim_win_get_cursor(0)
			-- Try to deduplicate
			local prev_id = M.state.find_duplicate(buf, pos[1], pos[2])
			if prev_id then
				M.state.current_id = prev_id
				M.state.places[prev_id].timestamp = vim.loop.hrtime()
			else
				M.state.register(buf, pos[1], pos[2])
			end

			M.buffer.refresh()
		end,
	})

	vim.api.nvim_create_user_command("PlacesTree", M.buffer.open, {})
	--vim.api.nvim_create_user_command("PlacesGo", function(opts)
	--	local id = tonumber(opts.args)
	--	M.buffer.jump(id)
	--end, { nargs = 1 })
end

return M
