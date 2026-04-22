local M = {
	-- Unique ID counter
	next_id = 1,
	-- Jumping in the preview UI
	jumping = false,
	-- Keep track of the current position in the tree. Nil means the tree is empty
	current_id = nil,
	-- Places tree
	places = {},
	-- Lookup table for (bufnr, line, column) -> id
	lookup = {},
}

local function new_id()
	local id = M.next_id
	M.next_id = id + 1
	return id
end

-- Get preview lines
local function preview_lines(bufnr, line)
	local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)

	if not line_text or not line_text[1] then return "" end
	return line_text[1]:match"^%s*(.*)"
end

-- Register a new place
function M.register(bufnr, line, col)

	local filename = vim.api.nvim_buf_get_name(bufnr)

	-- Prevent duplicates
	if M.current_id then
		local cur = M.places[M.current_id]
		if cur and cur.bufnr == bufnr and cur.line == line then return end
	end

	-- Insert place
	local id = new_id()
	M.places[id] = {
		id        = id,
		bufnr     = bufnr,
		filename  = filename,
		line      = line,
		col       = col,
		timestamp = vim.loop.hrtime(),
		line_text = preview_lines(bufnr, line),
		parent_id = M.current_id,
		children  = {},
	}
	local lookup_key = string.format("%d:%d:%d", bufnr, line, col)
	M.lookup[lookup_key] = id

	-- Add as children if we're not at the bottom of a branch
	if M.current_id then
		local parent = M.places[M.current_id]
		if parent then parent.children[#parent.children + 1] = id end
	end

	M.current_id = id -- M.next_id
end

function M.find_duplicate(bufnr, line, col)
	local lookup_key = string.format("%d:%d:%d", bufnr, line, col)
	return M.lookup[lookup_key]
end

-- Update a node
function M.update_node(id, line, col)
	local node = M.places[id]

	-- Remove previous lookup entry
	local lookup_key = string.format("%d:%d:%d", node.bufnr, node.line, node.col)
	M.lookup[lookup_key] = nil

	node.timestamp = vim.loop.hrtime()
	node.line = line
	node.col = col
	node.line_text = preview_lines(node.bufnr, line)

	-- Insert new lookup entry
	lookup_key = string.format("%d:%d:%d", node.bufnr, node.line, node.col)
	M.lookup[lookup_key] = id
end

function M.on_cursor_moved(bufnr, line, col)

	local node = M.current_id and M.places[M.current_id]

	if not node or node.bufnr ~= bufnr then return end
	M.update_node(M.current_id, line, col)

end

function M.setup()
	M.util = require("places.util")
end

return M
