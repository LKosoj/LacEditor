function Image(image)
  local source = image.src
  -- GFM otherwise emits raw HTML for image dimensions, which the preview hides.
  image.attr = pandoc.Attr()
  if source:match('^data:') then return image end
  local mime, contents = pandoc.mediabag.lookup(source)
  if not contents then
    -- Keep network and other URI references unchanged; never fetch them here.
    if (source:match('^[%a][%w+.-]*:') and not source:match('^file:')) or source:match('^//') then return image end
    mime, contents = pandoc.mediabag.fetch(source)
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
