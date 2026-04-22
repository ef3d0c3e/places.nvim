local M = {}

-- Check if a buffer should be tracked by the plugin
function M.is_trackable(bufnr)
	-- Skip if in floating window
	local win = vim.api.nvim_get_current_win()
	local cfg = vim.api.nvim_win_get_config(win)
	if cfg.relative ~= "" then
		return
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then return false end
	if vim.bo[bufnr].buftype ~= "" then return false end
	if not vim.bo[bufnr].buflisted then return false end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then return false end
	if vim.fn.filereadable(name) ~= 1 then return false end
	return true
end

return M
