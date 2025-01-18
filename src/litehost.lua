-- serialization
local serpent = require'serpent'
local common = require "core.common"

local function serialize(...)
  return serpent.line({...}, {comment=false})
end


local m = {}

m.__index = m
m.editors = {}
m.loaded_fonts = {}
m.focused = nil
m.plugin_callbacks = {}
-- the general channel is used to communicate instance name to its thread
m.general_channel = lovr.thread.getChannel('lite-editors')


-- create an editor instance
function m.new()
  local self = setmetatable({}, m)
  self.name = 'lite-editor-' .. tostring(#m.editors + 1)
  self.size = {1000, 1000}
  self.current_frame = {}
  self.pose = lovr.math.newMat4()
  --self:center()

  -- start the editor thread and set up the communication channels
  local threadcode = lovr.filesystem.read('litethread.lua')
  self.thread = lovr.thread.newThread(threadcode)
  self.thread:start()
  m.general_channel:push(serialize('new_thread', self.name)) -- announce
  self.outbount_channel = lovr.thread.getChannel(string.format('%s-events', self.name))
  self.inbound_channel = lovr.thread.getChannel(string.format('%s-render', self.name))
  table.insert(m.editors, self)
  m.set_focus(#m.editors) -- set focus to newly created editor instance
  return self
end


function m.set_focus(editorindex)
  m.focused = editorindex
  for i, editor in ipairs(m.editors) do
    editor.outbount_channel:push(serialize('set_focus', i == m.focused))
  end
end


--------- keyboard handling ---------

local function expand_key_names(key)
  if key:sub(1, 2) == "kp" then
    return "keypad " .. key:sub(3)
  end
  if key:sub(2) == "ctrl" or key:sub(2) == "shift" or key:sub(2) == "alt" or key:sub(2) == "gui" then
    if key:sub(1, 1) == "l" then return "left " .. key:sub(2) end
    return "right " .. key:sub(2)
  end
  return key
end


function m.keypressed(key, scancode, rpt)
  if m.editors[m.focused] then
    m.editors[m.focused].outbount_channel:push(serialize('keypressed', expand_key_names(key)))
  end
end


function m.keyreleased(key, scancode)
  if m.editors[m.focused] then
    m.editors[m.focused].outbount_channel:push(serialize('keyreleased', expand_key_names(key)))
  end
end


function m.textinput(text, code)
  if m.editors[m.focused] then
    m.editors[m.focused].outbount_channel:push(serialize('textinput', text))
  end
end

--------- callbacks for all instances ---------

function m.update()
  for plugin_name, callbacks in pairs(m.plugin_callbacks) do
    if callbacks.update then callbacks.update() end
  end
  for i, instance in ipairs(m.editors) do
    instance:update_instance()
  end
end


-- needs to be called last in draw order because drawing doesn't write to depth buffer 
function m.draw(pass)
  for plugin_name, callbacks in pairs(m.plugin_callbacks) do
    if callbacks.draw then callbacks.draw(pass) end
  end
  for i, instance in ipairs(m.editors) do
    instance:draw_instance(pass)
  end
end


-- error handler that ensures the editor survives user app errors in order to be able to fix them
-- should be assigned to lovr.errhand early in execution, to catch as many errors
function m.errhand(message, traceback)
  traceback = traceback or debug.traceback('', 4)
  for _, instance in ipairs(m.editors) do
    instance.outbount_channel:push(serialize('lovr_error_message', message, traceback))
  end
  lovr.graphics.setBackgroundColor(0x14162c)
  lovr.draw = m.draw
  lovr.update = m.update
  return function() -- a minimal lovr run loop, with lite still working
    lovr.system.pollEvents()
    local dt = lovr.timer.step()
    for name, a, b, c, d in lovr.event.poll() do
      if name == 'quit' then 
        return a or 1
      elseif name == 'restart' then
        return 'restart'
      elseif lovr.handlers[name] then
        lovr.handlers[name](a, b, c, d)
      end
    end
    local pass = lovr.graphics.getWindowPass()
    pass:origin()
    if lovr.headset and lovr.headset.getDriver() ~= 'desktop' then
      lovr.headset.update(dt)
      lovr.headset.renderTo(m.draw)
    end
    lovr.update(dt)

    lovr.graphics.submit(pass)
    lovr.graphics.present()
    lovr.math.drain()
  end
end


-- inserts all important functions into callback chain, so they don't have to be called manually
-- needs to be called at the end of `main.lua` once user app functions are already defined
function m.inject_callbacks()
  local chained_callbacks = {'keypressed', 'keyreleased', 'textinput', 'update', 'draw'}
  local stored_cb = {}
  for _, cb in ipairs(chained_callbacks) do
    stored_cb[cb] = lovr[cb]
  end
  -- inject this module's cb after original callback is called
  for _, cb in ipairs(chained_callbacks) do
    lovr[cb] = function(...)
      if stored_cb[cb] then
        stored_cb[cb](...) -- call user app callback
      end
      m[cb](...) -- call own callback
    end
  end
end

--------- inbound event handlers ---------

m.event_handlers = {
  begin_frame = function(self, pass)
   pass:setDepthTest('gequal')
  end,

  end_frame = function(self, pass)
    last_time = lovr.timer.getTime()
    pass:setDepthTest('gequal')
    pass:setStencilTest('none')
  end,

  set_litecolor = function(self, pass, r, g, b, a)
    pass:setColor(r, g, b, a)
  end,

  set_clip_rect = function(self, pass, x, y, w, h)
    pass:setColorWrite(false)
    pass:setDepthWrite(false)
    pass:setStencilTest('none')
    pass:setStencilWrite('zero')
    pass:fill()
    pass:setStencilWrite('replace')
    
    pass:plane(x + w/2, -y - h/2, 0, w, h)
    pass:setStencilWrite('keep')
    pass:setStencilTest('greater', 0)
    pass:setColorWrite(true)
    pass:setDepthWrite(true)
  end,

  draw_rect = function(self, pass, x, y, w, h)
    local cx =  x + w/2
    local cy = -y - h/2
    pass:plane(cx, cy, 0, w, h)
  end,

  draw_text = function(self, pass, text, x, y, filename, size)
    local fontname = string.format('%q:%d', filename, size)
    local font = m.loaded_fonts[fontname]
    if not font then
      font = lovr.graphics.newFont(filename, size)
      font:setPixelDensity(1)
      m.loaded_fonts[fontname] = font
    end
    
    pass:setFont(font)
    local rasterizer = font:getRasterizer()
    local utf8_chars = common.utf8_chars(tostring(text))
    local max_width = rasterizer:getWidth()
    local default_width = rasterizer:getAdvance("a")
    local chunk = {text = "", x = 0.0, y = 0.0, width = 0.0 }
    local unknown_char = "?"
    local unknown_char_width = rasterizer:getAdvance(unknown_char)
    local function drawChunk()
      if chunk.text ~= "" then
         pass:text(chunk.text, x + chunk.x, -y - chunk.y, 0,  1,  0, 0,1,0, nil, 'left', 'top')
      end
      chunk.text = ""
      chunk.x = chunk.x + chunk.width
      chunk.width = 0
    end
    local prev_utf8_char = nil
    for utf8_char in utf8_chars do
      local char_width = rasterizer:getAdvance(utf8_char)
      local valid_character = char_width > 0 and char_width <= max_width
      if valid_character then
         chunk.text = chunk.text .. utf8_char
         chunk.width = chunk.width + char_width
         if prev_utf8_char ~= nil then
            local kerning = rasterizer:getKerning(prev_utf8_char, utf8_char)
            chunk.width = chunk.width + kerning
         end
         prev_utf8_char = utf8_char
      else
         drawChunk()
         if utf8_char == " " then
            chunk.x = chunk.x + default_width
         elseif utf8_char == "\t" then
            chunk.x = chunk.x +  default_width * 3 -- TODO: Tab setting?
         else
            chunk.text = chunk.text .. unknown_char
            chunk.width = chunk.width + unknown_char_width
         end
      end
      
    end
    drawChunk()
    
  end,

  register_plugin = function(self, pass, plugin_name, plugin_callbacks)
    local was_already_registered = not not m.plugin_callbacks[plugin_name]
    m.plugin_callbacks[plugin_name] = plugin_callbacks
    if not was_already_registered then
      for event, handler_fn in pairs(plugin_callbacks or {}) do
        if event == 'load' then
          plugin_callbacks.load(self)
        else
          m.event_handlers[event] = handler_fn
        end
      end
    end
  end,
}

--------- per-instance methods ---------

function m:draw_instance(pass)
  pass:push()
  
  --print("Headset: ", (lovr.headset and lovr.headset.getDriver() ~= 'desktop'))
  --print("projections: ", pass:getProjection(1))
  --print("ViewPose: ", pass:getViewPose(1))
  pass:transform(self.pose)
  

  
  -- Get everything in a visible position
  pass:translate(0, 0, -130)
  --pass:translate(0, 0, 1)
  
  --pass:plane(0, 0, 0, 0.5, 0.5)
  --pass:text('hello world', 0, 0, -5, 1)

  --pass:scale(1 / 1000)--math.max(self.size[1], self.size[2]))
  --pass:rotate(3.14 / 4, 0, 0, 1)
  --pass:plane(0, 0, 0, 10, 10)
  --pass:plane(1000, 0, 0, 10, 10)
  
  pass:translate(-self.size[1] / 2, self.size[2] / 2)
  

  --pass:plane(500, -500, 0, 1000, 1000)
  
  for i, draw_call in ipairs(self.current_frame) do
    local fn = m.event_handlers[draw_call[1]]
    fn(self, pass, select(2, unpack(draw_call)))
  end
  pass:pop()
end


function m:update_instance()
  local req_str = self.inbound_channel:pop(false)
  if req_str then
    local ok, current_frame = serpent.load(req_str, {safe = false})
    if ok then
      self.current_frame = current_frame
    end
  end
end


function m:resize(width, height)
  self.size = {width, height}
  self.outbount_channel:push(serialize('resize', width, height))
end


function m:center()
  if not (lovr.headset and lovr.headset.getDriver() ~= 'desktop') then
    self.pose:set(-0, 0, -0.8)
  else
    local headpose = mat4(lovr.headset.getPose())
    local headpos = vec3(headpose)
    local pos = vec3(headpose:mul(0, 0, -0.7))
    self.pose:target(pos, headpos)
    self.pose:rotate(math.pi, 0,1,0)
  end
end


return m
