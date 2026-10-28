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
