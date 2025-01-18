local litehost = require 'litehost'
--lovr.errhand = litehost.errhand
local editor = litehost.new()


-- insert user app code here, or require project's main.lua file
function lovr.draw(pass)
   pass:setViewPose(1, 0, 0, 0, 0, 0, 1, 0)
end

litehost.inject_callbacks()
