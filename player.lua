Player = { corners = {-6, 5, -22, -0.5} }
Player.__index = Player

local RUN_SPEED = 500 -- Run acceleration
local MAX_SPEED = 160 -- Maximum running speed
local MAX_SPEED_CARRY = 100 -- Maximum running speed when carrying human
local BRAKE_SPEED = 250
local GRAVITY = 350
local JUMP_POWER = 130 -- initial yspeed when jumping
local CLIMB_SPEED = 60 -- climbing speed
local STREAM_SPEED = 400 -- stream growth speed
local MAX_STREAM = 100 -- maximum stream length
local USE_RATE   = 2.5
local BURN_DAMAGE = 0.5 -- Damage over time when touching enemies
local TIME_DAMAGE = 0.01
local FIRE_DIST = 1600

local PS_RUN, PS_CLIMB, PS_CARRY, PS_THROW = 0,1,2,3 -- Player states
local GD_UP, GD_HORIZONTAL, GD_DOWN = 0,2,4 -- Gun directions

local lg = love.graphics

function Player.create(x,y)
	local self = setmetatable({}, Player)

	self.x, self.y = x, y

	self.xspeed = 0
	self.yspeed = 0
	self.onGround = false
	self.time = 0
	self.lastDir = 1

	self.shooting = false
	self.streamLength = 0
	self.streamCollided = false
	self.wquad = love.graphics.newQuad(0,0,10,10, 16,16) -- water stream quad

	self.regen_rate = 3.0
	self.water_capacity = 5
	self.water = self.water_capacity
	self.overloaded = false

	self.temperature = 0
	self.heat = 0

	self.grabbed = nil -- grabbed human

	self.state = PS_RUN
	self.gundir = GD_HORIZONTAL -- gun direction

	self.dir = 1 -- -1 for left, 1 for right

	self.animRun 	    = newAnimation(img.player_running, 16, 22, 0.12, 4)
	self.animThrow      = newAnimation(img.player_throw, 16,32, 0.12, 4)
	self.animClimb      = newAnimation(img.player_climb_down, 14, 23, 0.12, 4)
	self.animCarryLeft  = newAnimation(img.human_1_carry_left,  22, 32, 0.12, 4)
	self.animCarryRight = newAnimation(img.human_1_carry_right, 22, 32, 0.12, 4)

	self.anim = self.animRun
	self.waterFrame = 0
	
	self.keys = {
		up = "w", down = "s", left = "a", right = "d", jump = " ", shoot = "j", action = "k"
	}

	return self
end

function Player:warp(x,y)
	self.x, self.y = x,y
	self.xspeed, self.yspeed = 0,0
end

--- Updates the player
-- Called once once each love.update
-- @param dt Time passed since last update
function Player:update(dt)
	self.shooting = false

	-- RUNNING STATE
	if self.state == PS_RUN then
		self:updateRunning(dt)
		self:updateGun(dt)
	elseif self.state == PS_CLIMB then
		self:updateClimbing(dt)
	elseif self.state == PS_CARRY then
		self:updateRunning(dt)
		if self.dir == -1 then
			self.anim = self.animCarryLeft
			self.anim.img = img.human_carry_left[self.grabbed.id]
		else
			self.anim = self.animCarryRight
			self.anim.img = img.human_carry_right[self.grabbed.id]
		end
	elseif self.state == PS_THROW then
		self:updateRunning(dt)
		self.time = self.time - dt
		if self.time <= 0 then
			self:setState(PS_RUN)
		end
	end

	-- Regen water
	if self.overloaded == true then
		self.water = cap(self.water+0.5*self.regen_rate*dt, 0, self.water_capacity)
		if self.water >= self.water_capacity then
			self.overloaded = false
		end
	else
		self.water = cap(self.water+self.regen_rate*dt, 0, self.water_capacity)
	end

	-- Update animations
	self.anim:update(dt)
	self.waterFrame = self.waterFrame + dt*10

	-- Collide fire
	self:collideFire(dt)
	self.temperature = self.temperature + TIME_DAMAGE*dt
	self.temperature = cap(self.temperature, 0, 1)
end

--- Called each update if current state is PS_RUN
-- @param dt Time passed since laste update
function Player:updateRunning(dt)
	local changedDir = false -- true if player changed horizontal direction

	-- Check if both directions are held for handling conflicts
	local both = love.keyboard.isDown(self.keys.right) and love.keyboard.isDown(self.keys.left)

	if (both == false and love.keyboard.isDown(self.keys.right)) or (both == true and self.lastDir == 1) then
		self.xspeed = self.xspeed + RUN_SPEED*dt

		if self.dir == -1 then
			self.dir = 1
			changedDir = true
		end

	elseif (both == false and love.keyboard.isDown(self.keys.left)) or (both == true and self.lastDir == -1) then
		self.xspeed = self.xspeed - RUN_SPEED*dt

		if self.dir == 1 then
			self.dir = -1
			changedDir = true
		end
	end

	if self.state == PS_CARRY then
		self.xspeed = cap(self.xspeed, -MAX_SPEED_CARRY, MAX_SPEED_CARRY)
	else
		self.xspeed = cap(self.xspeed, -MAX_SPEED, MAX_SPEED)
	end

	if changedDir == true and self.gundir == GD_HORIZONTAL then
		self.streamLength = 0
	end

	-- Cap speeds
	if self.xspeed < 0 then
		self.xspeed = self.xspeed + math.max(dt*BRAKE_SPEED, self.xspeed)
	elseif self.xspeed > 0 then
		self.xspeed = self.xspeed - math.min(dt*BRAKE_SPEED, self.xspeed)
	end

	-- Move in x axis
	self.x = self.x + self.xspeed*dt
	if collideX(self) == true then
		self.xspeed = -1.0*self.xspeed
	end
	-- Update gravity
	self.yspeed = self.yspeed + GRAVITY*dt
	-- Move in y axis
	self.y = self.y + self.yspeed*dt
	if collideY(self) == true then
		self.yspeed = 0
	end

	-- Set animation speeds
	self.anim:setSpeed(math.abs(self.xspeed)/MAX_SPEED)
end

function Player:collideFire(dt)
	self.heat = 0
	for i,v in ipairs(map.enemies) do
		if self:collideBox(v:getBBox()) == true then
			self.heat = 1
			break
		end
	end

	local cx = math.floor(self.x/16)
	local cy = math.floor((self.y-11)/16)

	local fireHeat = 0
	for ix = cx-2,cx+2 do
		for iy = cy-2,cy+2 do
			if map:hasFire(ix,iy) == true then
				local fx, fy = ix*16+8, iy*16+8
				local dist = math.pow(self.x-fx,2) + math.pow(self.y-fy-11,2)

				if dist <= FIRE_DIST then
					local contrib = math.pow((0.5*math.cos((dist/FIRE_DIST)*math.pi)+0.5), 3)
					fireHeat = fireHeat + contrib
				end
			end
		end
	end

	self.heat = cap(self.heat + fireHeat, 0, 1)
	self.temperature = self.temperature + self.heat*BURN_DAMAGE*dt
end

--- Updates gun direction and stream
function Player:updateGun(dt)
	-- Find gundirection
	local old_gundir = self.gundir
	self.gundir = GD_HORIZONTAL
	if love.keyboard.isDown(self.keys.up) then
		self.gundir = GD_UP
	elseif love.keyboard.isDown(self.keys.down) then
		self.gundir = GD_DOWN
	end
	if self.gundir ~= old_gundir or changedDir and self.gundir == HORIZONTAL then
		self.streamLength = 0
	end

	-- Update stream length and collide it with entities/walls
	self:updateStream(dt)
end

--- Updates the water stream
-- Updates the length of the water stream
-- and performs collision with walls and other entities
function Player:updateStream(dt)
	-- Shoot
	if love.keyboard.isDown(self.keys.shoot) and self.overloaded == false then
		self.shooting = true
		self.streamLength = math.min(self.streamLength + STREAM_SPEED*dt, MAX_STREAM)
	else
		self.shooting = false
		self.streamLength = 0
		return
	end

	self.water = self.water - (USE_RATE+self.regen_rate)*dt
	if self.water <= 0 then
		self.overloaded = true
	end

	-- Collide with walls
	local span = math.ceil((self.streamLength+12)/16)
	local cx = math.floor(self.x/16)
	local cy = math.floor((self.y-6)/16)
	self.streamCollided = false

	if self.gundir == GD_UP then -- up
		for i = 1,span do
			cy = cy - 1
			if map:collideCell(cx,cy) == true then
				map:hitCell(cx,cy,self.dir)
				self.streamLength = self.y-(cy+1)*16-20
				self.streamCollided = true
				break
			end
		end
	elseif self.gundir == GD_DOWN then -- down
		for i = 1,span do
			cy = cy + 1
			if map:collideCell(cx,cy) == true then
				map:hitCell(cx,cy,self.dir)
				self.streamLength = cy*16-self.y-4
				self.streamCollided = true
				break
			end
		end
	elseif self.gundir == GD_HORIZONTAL then -- horizontal
		--cx = cx - self.dir
		for i = 1,span do
			cx = cx + self.dir
			if map:collideCell(cx,cy) == true then
				map:hitCell(cx,cy,self.dir)
				if self.dir == -1 then
					self.streamLength = self.x-(cx+1)*16-13
				else
					self.streamLength = cx*16-self.x-10
				end
				self.streamCollided = true
				break
			end
		end
	end

	-- Collide with entities
	-- Calculate stream's collision box (table creation each frame!)
	local sbox
	if self.gundir == GD_UP then -- up
		sbox = {x = self.x-4.5, y = self.y-17-self.streamLength, w = 9, h = self.streamLength}
	elseif self.gundir == GD_HORIZONTAL then -- horizontal
		if self.dir == -1 then
			sbox = {x = self.x-9-self.streamLength, y = self.y-10, w = self.streamLength, h = 9}
		else
			sbox = {x = self.x+9, y = self.y-10, w = self.streamLength, h = 9}
		end
	elseif self.gundir == GD_DOWN then -- down
		sbox = {x = self.x-4.5, y = self.y+1, w = 9, h = self.streamLength}
	end

	-- Collide with enemies
	local closestHit = nil
	local min = 9999
	-- Collide with objects and entities
	for j,w in ipairs({map.humans, map.objects, map.enemies}) do
		for i,v in ipairs(w) do
			if v:collideBox(sbox) == true then
				local dist = self:cutStream(v:getBBox())
				if dist < min then 
					closestHit = v
					min = dist
				end
				self.streamCollided = true
			end
		end
	end
	-- Collide with fire
	for j,w in pairs(map.fire) do
		for i,v in pairs(w) do
			if v:collideBox(sbox) == true then
				local dist = self:cutStream(v:getBBox())
				if dist < min then
					closestHit = v
					min = dist
				end
				self.streamCollided = true
			end
		end
	end
	-- If an object was hit, cut stream and hit object
	if closestHit ~= nil then
		closestHit:shot(dt,self.dir)
		self.streamLength = min
	end
	-- Cap stream length
	self.streamLength = math.max(0, self.streamLength)
end

--- Cuts the stream off after colliding with a bounding box
-- @param box Bounding box stream collided with
function Player:cutStream(box)
	if self.gundir == GD_HORIZONTAL then -- horizontal
		if self.dir == -1 then -- left
			return self.x - (box.x+box.w)-11
		else
			return box.x - self.x-9
		end
	elseif self.gundir == GD_UP then -- up
		return self.y - (box.y+box.h+18)
	elseif self.gundir == GD_HORIZONTAL then -- down
		return box.y - self.y-4
	else
		return 0
	end
end

--- Called each update if the current state is PS_CLIMB
-- @param dt Time passed since last update
function Player:updateClimbing(dt)
	local oldy = self.y
	-- Move up and down ladder
	local animSpeed = 0
	if love.keyboard.isDown(self.keys.down) then
		self.y = self.y + CLIMB_SPEED*dt
		self.animClimb.direction = 1
		animSpeed = 1
	end
	if love.keyboard.isDown(self.keys.up) then
		self.y = self.y - CLIMB_SPEED*dt
		self.animClimb.direction = -1
		animSpeed = 1
	end
	self.anim:setSpeed(animSpeed)

	-- Check if player has moved off ladder
	local idBottom = map:getPoint(self.x, self.y)
	local idMid = map:getPoint(self.x, self.y-11)
	local idTop = map:getPoint(self.x, self.y-22)
	if idBottom == 2 or idBottom == nil then -- over ladder
		self.y = oldy
		self:setState(PS_RUN)
	elseif idBottom ~= 5 and idBottom ~= 8 and idBottom ~= 137
	and idBottom ~= 153 and idBottom ~= 247 then
		self:setState(PS_RUN)
	end
end

function Player:leaveLadder()
	local idBottom = map:getPoint(self.x, self.y)
	local idMid = map:getPoint(self.x, self.y-11)
	local idTop = map:getPoint(self.x, self.y-22)
	if  idBottom ~= 5 and idMid ~= 5 and idTop ~= 5
	and idBottom ~= 8 and idMid ~= 8 and idTop ~= 8 then
		self:setState(PS_RUN)
	end
end

function Player:keypressed(k)
	if k == self.keys.jump then
		self:jump()
	elseif k == self.keys.action then
		if self.state == PS_RUN then
			if self:climb() == false then
				self:grab()
			end
		elseif self.state == PS_CARRY then
			self:setState(PS_THROW)
			self.grabbed:throw(self.x, self.y, self.dir)
			self.grabbed = nil
		elseif self.state == PS_CLIMB then
			self:leaveLadder()
		end
	elseif k == self.keys.left or k == self.keys.right then
		-- Save last direction for conflicts
		if k == self.keys.left then
			self.lastDir = -1
		else
			self.lastDir = 1
		end

		if self.state == PS_CLIMB then
			self:leaveLadder()
		end
	end
end

--- Changes the current state and resets current animation
-- @param state New state
function Player:setState(state)
	if state == PS_RUN then
		self.state = PS_RUN
		self.anim = self.animRun
	elseif state == PS_CLIMB then
		self.state = PS_CLIMB
		self.anim = self.animClimb
		self.xspeed, self.yspeed = 0,0
		self.x = math.floor(self.x/16)*16+8 -- Align with middle of ladder
	elseif state == PS_CARRY then
		self.state = PS_CARRY
	elseif state == PS_THROW then
		self.state = PS_THROW
		self.anim = self.animThrow
		self.time = 0.4
	end

	self.streamLength = 0
	self.anim:reset()
end

function Player:jump()
	if self.onGround == true then
		self.yspeed = -JUMP_POWER
	elseif self.state == PS_CLIMB then
		self:leaveLadder()
	end
end

--- Called when player tries to grab a ladder
-- @return True if a ladder was grabbed
function Player:climb()
	if self.gundir == GD_UP or self.gundir == GD_DOWN then
		local below = map:getPoint(self.x, self.y+1)
		local top    = map:getPoint(self.x, self.y-22)
		if below == 5 or below == 137 or below == 153 or below == 8 or below == 247
		or top == 5 or top == 137 or top == 153 or top == 8 or top == 247 then
			self:setState(PS_CLIMB)
			return true
		end
	end
	return false
end

function Player:grab()
	for i,v in ipairs(map.humans) do
		if self:collideBox(v:getBBox()) and v:canGrab() == true then
			self.grabbed = v
			self:setState(PS_CARRY)
			v:grab()
			return
		end
	end
end

function Player:collideBox(bbox)
	if self.x-6  > bbox.x+bbox.w or self.x+5 < bbox.x
	or self.y-22 > bbox.y+bbox.h or self.y   < bbox.y then
		return false
	else
		return true
	end
end

function Player:draw()
	-- Floor position
	self.flx = math.floor(self.x)
	self.fly = math.floor(self.y)

	if self.state == PS_RUN then
		-- Draw player
		if self.onGround == false then
			self.anim:draw(self.flx, self.fly, 0, self.dir, 1, 8, 22, 2)
		elseif math.abs(self.xspeed) < 30 then
			self.anim:draw(self.flx, self.fly, 0, self.dir, 1, 8, 22, 4)
		else
			self.anim:draw(self.flx, self.fly, 0, self.dir, 1, 8, 22)
		end

		-- Draw gun
		lg.drawq(img.player_gun, quad.player_gun[self.gundir], self.flx, self.fly-16, 0, self.dir, 1, 3, 0)

		-- Draw water
		if self.shooting == true then
			self:drawWater()
		end
	-- Climbing
	elseif self.state == PS_CLIMB then
		self.anim:draw(self.flx, self.fly, 0, 1,1, 7, 22)
	-- Carrying a human
	elseif self.state == PS_CARRY then
		if math.abs(self.xspeed) < 30 then
			if self.dir == -1 then
				self.anim:draw(self.flx, self.fly, 0, 1,1, 12, 32, 1)
			else
				self.anim:draw(self.flx, self.fly, 0, 1,1, 12, 32, 1)
			end
		else
			self.anim:draw(self.flx, self.fly, 0, 1,1, 12, 32)
		end
	-- Throwing human
	elseif self.state == PS_THROW then
		if self.onGround == false then
			self.anim:draw(self.flx, self.fly, 0,self.dir,1, 8, 22, 2)
		elseif math.abs(self.xspeed) < 30 then
			self.anim:draw(self.flx, self.fly, 0,self.dir,1, 8, 22, 4)
		else
			self.anim:draw(self.flx, self.fly, 0,self.dir,1, 8, 22)
		end
	end
end

function Player:drawWater()
	local quadx = 8-math.floor((self.waterFrame*8)%8)
	self.wquad:setViewport(quadx, 0, math.floor(self.streamLength), 9)
	local frame = math.floor(self.waterFrame%2)

	if self.gundir == GD_UP then -- up
		if self.streamLength > 0 then
			lg.drawq(img.stream, self.wquad, self.flx, self.fly, -math.pi/2, 1, self.dir, -19, 4)
			if self.streamCollided == false then
				lg.drawq(img.water, quad.water_end[frame], self.flx+self.dir*0.5, self.fly-20-math.floor(self.streamLength), -math.pi/2, 1,1, 8, 7.5)
			else
				lg.drawq(img.water, quad.water_hit[frame], self.flx+self.dir*0.5, self.fly-13-math.floor(self.streamLength), -math.pi/2, 1,1, 8, 9.5)
			end
		end
		lg.drawq(img.water, quad.water_out[frame], self.flx+self.dir*0.5, self.fly-16, -math.pi/2, 1,1, 0,7.5)

	elseif self.gundir == GD_HORIZONTAL then -- horizontal
		if self.streamLength > 0 then
			lg.drawq(img.stream, self.wquad, self.flx+self.dir*11, self.fly-10, 0, self.dir, 1)
			if self.streamCollided == false then
				lg.drawq(img.water, quad.water_end[frame], self.flx+self.dir*(11+math.floor(self.streamLength)), self.fly-5, 0, self.dir,1, 7.5, 8)
			else
				lg.drawq(img.water, quad.water_hit[frame], self.flx+self.dir*(6.5+math.floor(self.streamLength))-1, self.fly-7, 0, self.dir,1, 9.5, 8)
			end
		end
		lg.drawq(img.water, quad.water_out[frame], self.flx, self.fly, 0, self.dir,1, -9,13)
	
	elseif self.gundir == GD_DOWN then -- down
		if self.streamLength > 0 then
			lg.drawq(img.stream, self.wquad, self.flx, self.fly, -math.pi/2, -1, self.dir, -5, 4)
			if self.streamCollided == false then
				lg.drawq(img.water, quad.water_end[frame], self.flx+self.dir*0.5, self.fly+math.floor(self.streamLength), math.pi/2, 1,1, 5, 7.5)
			else
				lg.drawq(img.water, quad.water_hit[frame], self.flx+self.dir*0.5, self.fly+math.floor(self.streamLength)+1, math.pi/2, 1,1, 11, 9.5)
			end
		end
		lg.drawq(img.water, quad.water_out[frame], self.flx+self.dir*0.5, self.fly+2, math.pi/2, 1,1, 0,7.5)
	end
end
