local function canonical_path(path)
  local ok, resolved = pcall(pandoc.pipe, '/bin/realpath', {'-q', path}, '')
  if not ok then return nil end
  if resolved:sub(-1) == '\n' then resolved = resolved:sub(1, -2) end
  return resolved
end

local source_root = canonical_path(pandoc.path.directory(PANDOC_STATE.input_files[1]))
local source_prefix = source_root and (source_root == '/' and '/' or source_root .. '/')

local function percent_decode(path)
  return path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
end

local function inside_source(path)
  return source_root and (path == source_root or path:sub(1, #source_prefix) == source_prefix)
end

function Image(image)
  local source = image.src
  -- GFM otherwise emits raw HTML for image dimensions, which the preview hides.
  image.attr = pandoc.Attr()
  if source:match('^data:') then return image end
  local mime, contents = pandoc.mediabag.lookup(source)
  if not contents then
    local path = percent_decode(source)
    -- Keep network and other URI references unchanged; never fetch them here.
    if path:match('^//') then return image end
    local scheme = path:match('^([%a][%w+.-]*):')
    if scheme and scheme:lower() ~= 'file' then return image end
    if scheme or path:find('\0', 1, true) or path:sub(1, 1) == '/' then error('Cannot read image: ' .. source) end
    local resolved = source_root and canonical_path(pandoc.path.join({source_root, path}))
    if not resolved or not inside_source(resolved) then error('Cannot read image: ' .. source) end
    mime, contents = pandoc.mediabag.fetch(resolved)
  end
  if not contents then error('Cannot read image: ' .. source) end
  image.src = pandoc.mediabag.make_data_uri(mime or '', contents)
  return image
end

local figure_warning_reported = false

local function unsupported_figure()
  if not figure_warning_reported then
    pandoc.log.warn('LACEDITOR_UNSUPPORTED_FIGURE')
    figure_warning_reported = true
  end
  return nil
end

function Figure(figure)
  if figure.identifier ~= '' or #figure.classes > 0 or #figure.content ~= 1 then return unsupported_figure() end
  for _ in pairs(figure.attributes) do return unsupported_figure() end
  local block = figure.content[1]
  if (block.t ~= 'Plain' and block.t ~= 'Para') or #block.content ~= 1 or block.content[1].t ~= 'Image' then return unsupported_figure() end
  local blocks = figure.content
  if #figure.caption.long > 0 then
    for _, block in ipairs(figure.caption.long) do blocks:insert(block) end
  elseif figure.caption.short and #figure.caption.short > 0 then
    blocks:insert(pandoc.Para(figure.caption.short))
  end
  return blocks
end
