local express = {}
express.version = "1.0"

--[[ Definitions ]]--
local component = require("component")
local event = require("event")
local serialization = require("serialization")

local modem = component.modem

-- [[ Utility Functions ]]
express.LuaSerializer = function (v)
    if v.__type == "Request" then
        v.headers = serialization.unserialize(v.headers)
        v.body = serialization.unserialize(v.body)
    elseif v.__type == "Response" then
        local serializedArgs = {}
        for _, arg in pairs({v.vargs}) do
            if type(arg) == "table" then
                table.insert(serializedArgs, serialization.serialize(arg))
            else
                table.insert(serializedArgs, arg)
            end
        end
        v.vargs = table.unpack(serializedArgs)
    end
end

--[[ Request ]]
local Request = {
    __type = "Request"
}

function Request.new(server, address, port, distance, route, headers, body)
    local req = {
        __server = server,
        agent = {
            address = address,
            port = port,
            distance = distance
        },
        body = body,
        headers = headers,
        route = route
    }

    setmetatable(req, { __index = Request })

    for _, user in pairs(server._users) do
        user(req)
    end

    return req
end

--[[ Response ]]
local Response = {
    __type = "Response"
}

function Response:Send(...)
    if self.__sent then return false end
    self.vargs = ...
    for _, user in pairs(self.__server._users) do
        pcall(user, self)
    end

    local success = modem.send(self.__request.agent.address, self.__request.agent.port, "expServerResponse", self.headers, self.vargs)
    self.__sent = success
    return success
end

function Response:SetStatus(status)
    if self.__sent then return false end
    modem.send(self.__request.agent.address, self.__request.agent.port, "expServerStatus", self.headers, status)
    return self
end

function Response:SetHeaders(headers)
    self.headers = headers
    return self
end

function Response.new(server, request)
    local res = {
        __server = server,
        __request = request,
        __sent = false,
        headers = {}
    }
    
    setmetatable(res, { __index = Response})
    return res
end

--[[ Server Object ]]--
local Server = {
    __type = "Server",
    __listeners = {},
    _users = {}
}

-- Server utility functions
function Server:__validateRoute(route)
    for _, listener in pairs(self.__listeners) do
        if listener.path == route then return true end
    end
    return false
end

function Server:__getListenersFromPath(route)
    local listeners = {}
    for _, listener in pairs(self.__listeners) do
        if listener.path == route then 
            table.insert(listeners, listener)
        end
    end
    return listeners
end

function Server:__validateHeaders(headers, route)
    local listeners = self:__getListenersFromPath(route)

    if not headers.method then return false, "No method provided" end

    local function routeHasValidMethodListener()
        for _, listener in pairs(listeners) do
            if listener.method == headers.method then return true, listener end
        end
        return false
    end

    local listenerExists, listenerForMethod = routeHasValidMethodListener()
    if not listenerExists then return false, "No listener exists for this route and method" end
    return true, listenerForMethod
end

-- On and Once
function Server:on(route, method, ...)
    local args = { ... }

    local function onEvent(req, res)
        local middlewareIndex = 1

        local function nextMiddleware()
            middlewareIndex = middlewareIndex + 1
            
            if args[middlewareIndex] then
                args[middlewareIndex](req, res, nextMiddleware)
            end
        end

        if #args > 1 then
            args[1](req, res, nextMiddleware)
        else
            args[1](req, res)
        end
    end

    table.insert(self.__listeners, {
        path = route,
        method = method,
        callback = onEvent
    })
end

function Server:once(route, method, ...)
    local args = { ... }
    local listenerIndex = #self.__listeners + 1

    local function onEvent(req, res)
        table.remove(self.__listeners, listenerIndex)
        local middlewareIndex = 1

        local function nextMiddleware()
            middlewareIndex = middlewareIndex + 1
            
            if args[middlewareIndex] then
                args[middlewareIndex](req, res, nextMiddleware)
            end
        end

        if #args > 1 then
            args[1](req, res, nextMiddleware)
        else
            args[1](req, res)
        end
    end

    table.insert(self.__listeners, {
        path = route,
        method = method,
        callback = onEvent
    })
end

function Server:use(method)
    table.insert(self._users, method)
end 

-- Runtime
function Server:listen(port)
    -- Create runtime
    self.__listening = true
    local function createRuntime()
        while self.__listening do
            modem.open(port)
            local _, _, address, reqPort, distance, route, headers, body = event.pull("modem_message")

            local req = Request.new(self, address, reqPort, distance, route, headers, body)
            local res = Response.new(self, req)

            local routeIsValid = self:__validateRoute(req.route)
            if not routeIsValid then 
                res:SetStatus(400):Send({
                    error = "Route does not exist."
                }) 
            end

            local headersValid, listener = self:__validateHeaders(req.headers, req.route)
            if not headersValid then
                res:SetStatus(400):Send({
                    error = listener
                })
            end
            assert(listener, "Unknown error occured.")
            listener.callback(req, res)

        end
    end

    self.__coroutine = coroutine.create(createRuntime)
    return self
end

function Server:stop()
    self.__listening = false
end

express.Server = function ()
    local obj = {}
    setmetatable(obj, { __index = Server })
    return obj
end

return express
