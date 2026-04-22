local M = {}

M.config = {
	-- Alternating branch colors
	branch_colors = { "#81a1c1", "#ebcb8b", "#b48ead", "#a3be8c" },
	-- Edge characters
	edges = {
		-- Left/Up/Right branch
		LUR = "",
		-- Left/Up branch
		LU = "",
		-- Vertical line
		VERT = "",

		-- Active bottom node
		BOTA = "",
		-- Inactive bottom node
		BOT = "",

		-- Active vertical node
		MIDA = "",
		-- Inactive vertical node
		MID = "",

		-- Active top node
		TOPA = "",
		-- Inactive top node
		TOP = "",

		-- Active branching bottom node
		BOTBA = "",
		-- Inactive branching bottom node
		BOTB = "",

		-- Active vertical branching node
		MIDBA = "",
		-- Inactive vertical branching node
		MIDB = "",

	},
	buffer_name = { fg = "#da6af6", bold = true },
	separator = { fg = "#2d8f9b" },
	line_number = { fg = "#2d8f9b" },
	line_text = { link = "Comment" },
}

-- {{{ Sorting

-- Compute subtree score for sorting, the subtree scores are determined by the most recent (timestamp) node of each subtree
local function subtree_score(id, nodes, cookie)
	if cookie[id] ~= nil then
		return cookie[id]
	end

	local node = nodes[id]
	if not node then
		cookie[id] = -math.huge
		return cookie[id]
	end

	local best = node.timestamp or 0
	for _, cid in ipairs(node.children or {}) do
		best = math.max(best, subtree_score(cid, nodes, cookie))
	end

	cookie[id] = best
	return best
end

-- Get the list of children from a node, sorted according to most recently modified
local function sorted_children(node, nodes, cookie)
	local children = {}

	for _, cid in ipairs(node.children or {}) do
		if nodes[cid] then
			children[#children + 1] = cid
		end
	end

	table.sort(children, function(a, b)
		local sa = subtree_score(a, nodes, cookie)
		local sb = subtree_score(b, nodes, cookie)
		if sa == sb then
			local ta = nodes[a].timestamp or 0
			local tb = nodes[b].timestamp or 0
			if ta == tb then
				return a > b
			end
			return ta > tb
		end
		return sa > sb
	end)

	return children
end

-- A safe function to find the root. Currently not needed because root has id 1, but here for future proofing
local function find_root(nodes, current_id)
	local id = current_id
	while id and nodes[id] and nodes[id].parent_id do
		id = nodes[id].parent_id
	end
	return id
end

-- }}}

-- {{{ Rendering

-- Get the per-branch color, based on spine degree (separation from the main spine)
local function branch_color(deg)
	local num = #M.config.branch_colors

	local n = deg % num
	return "PlacesBranch_" .. tostring(n)
end

local function buffer_name(path)
	if not path or path == "" then
		return "[No Name]"
	end
	return vim.fn.fnamemodify(path, ":t")
end

-- Render tail edges characters
local function branch_tail(chunks, side_count)
	if side_count <= 0 then
		return
	end

	for i = 0, side_count - 1, 1 do
		if i == side_count - 1 then
			chunks[#chunks + 1] = { M.config.edges.LU, branch_color(i + 1) }
		else
			chunks[#chunks + 1] = { M.config.edges.LUR, branch_color(i + 1) }
		end
	end
end

local function row_chunks(node, depth, side_count, is_current)
	local chunks = {}

	if depth > 0 then
		for i = 0, depth - 1, 1 do
			chunks[#chunks + 1] = { M.config.edges.VERT, branch_color(i) }
		end
	end

	local edge = "*"
	if is_current then
		-- Has right branch
		if side_count > 0 then
			-- No parent
			if not node.parent_id then
				edge = M.config.edges.BOTBA
			else
				edge = M.config.edges.MIDBA
			end
			-- Top + Right branch is not possible
		else
			-- No parent
			if not node.parent_id then
				edge = M.config.edges.BOTA
				-- No children
			elseif #node.children == 0 then
				edge = M.config.edges.TOPA
			else
				edge = M.config.edges.MIDA
			end
		end
	else
		-- Has right branch
		if side_count > 0 then
			-- No parent
			if not node.parent_id then
				edge = M.config.edges.BOTB
			else
				edge = M.config.edges.MIDB
			end
			-- Top + Right branch is not possible
		else
			-- No parent
			if not node.parent_id then
				edge = M.config.edges.BOT
				-- No children
			elseif #node.children == 0 then
				edge = M.config.edges.TOP
			else
				edge = M.config.edges.MID
			end
		end
	end
	chunks[#chunks + 1] = { edge, branch_color(depth) }

	branch_tail(chunks, side_count)

	chunks[#chunks + 1] = { "  ", "Normal" }
	-- DEBUGGING:
	--chunks[#chunks + 1] = { "[" .. node.id .. "]", "BranchId" }
	chunks[#chunks + 1] = { buffer_name(node.filename), "PlacesBufferName" }
	chunks[#chunks + 1] = { ":", "PlacesSeparator" }
	chunks[#chunks + 1] = { tostring(node.line), "PlacesLineNumber" }
	chunks[#chunks + 1] = { "  ", "Normal" }
	chunks[#chunks + 1] = { node.line_text, "PlacesLineText" }


	return chunks
end

-- Build the array of rows for displaying
function M.build_rows()
	local nodes = M.state.places
	local current_id = M.state.current_id

	if not current_id or not nodes[current_id] then
		return {}
	end

	local root_id = find_root(nodes, current_id)
	if not root_id then
		return {}
	end

	local rows = {}
	local seen = {}
	local cookie = {}

	local function emit(id, depth)
		if seen[id] then
			return
		end

		local node = nodes[id]
		if not node then
			return
		end

		seen[id] = true

		local children = sorted_children(node, nodes, cookie)
		local main_child = children[1]

		local side_children = {}
		for i = 2, #children do
			side_children[#side_children + 1] = children[i]
		end

		-- Main spine first, then side branches.
		if main_child then
			emit(main_child, depth)
		end

		for i, sid in ipairs(side_children) do
			emit(sid, depth + i)
		end

		rows[#rows + 1] = {
			id = id,
			chunks = row_chunks(node, depth, #side_children, id == current_id),
		}
	end

	emit(root_id, 0)
	return rows
end

-- }}}

function M.setup(state, opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	M.state = state

	-- Branch highlights
	for id, color in ipairs(M.config.branch_colors) do
		local name = branch_color(id)
		vim.api.nvim_set_hl(0, name, { fg = color })
	end

	vim.api.nvim_set_hl(0, "PlacesBufferName", M.config.buffer_name)
	vim.api.nvim_set_hl(0, "PlacesSeparator", M.config.separator)
	vim.api.nvim_set_hl(0, "PlacesLineNumber", M.config.line_number)
	vim.api.nvim_set_hl(0, "PlacesLineText", M.config.line_text)
end

return M
