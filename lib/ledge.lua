local redis = require("lib.redis")
local config = require("lib.config")
local event = require("lib.event")
    
-- Perform assertions on the nginx config only on the first run
assert(ngx.var.cache_key, "cache_key not defined in nginx config")
assert(ngx.var.full_uri, "full_uri not defined in nginx config")
assert(ngx.var.relative_uri, "relative_uri not defined in nginx config")
assert(ngx.var.config_file, "config_file not defined in nginx config")
assert(ngx.var.loc_redis, "loc_redis not defined in nginx config")
assert(ngx.var.loc_origin, "loc_origin not defined in nginx config")

local ledge = {
    version = '0.1',

    config_file = assert(loadfile(ngx.var.config_file), "Config file not found"),
    cache = {}, -- Namespace

    states = {
        SUBZERO		= 1,
        COLD		= 2,
        WARM		= 3,
        HOT			= 4,
    },

    actions = {
        FETCHED		= 1,
        COLLAPSED	= 2,
    },
}


function ledge.main()
    -- Run the config to determine run level options for this request
    ledge.config_file()
    event.emit("config_loaded")

    if ledge.request_is_cacheable() then
        -- Prepare fetches from cache, so we're either primed with a full response
        -- to send, or cold with an empty response which must be fetched.
        ledge.prepare()

        local response = ngx.ctx.response
        -- Send and/or fetch, depending on the state
        if (response.state == ledge.states.HOT) then
            ledge.send()
        elseif (response.state == ledge.states.WARM) then
            ledge.background_fetch()
            ledge.send()
        elseif (response.state < ledge.states.WARM) then
            ngx.ctx.response = ledge.fetch()
            ledge.send()
        end
    else 
        ngx.ctx.response = { state = ledge.states.SUBZERO }
        ngx.ctx.response = ledge.fetch()
        ledge.send()
    end

    event.emit("finished")
end


-- Returns the current request method as an ngx.HTTP_{METHOD} constant.
--
-- @param   void
-- @return  const
function ledge.request_method_constant()
    local m = ngx.var.request_method
    if (m == "GET") then
        return ngx.HTTP_GET
    elseif (m == "POST") then
        return ngx.HTTP_POST
    elseif (m == "HEAD") then
        return ngx.HTTP_HEAD
    elseif (m == "PUT") then
        return ngx.HTTP_PUT
    elseif (m == "DELETE") then
        return ngx.HTTP_DELETE
    else
        return nil
    end
end


-- Returns the state name as string (for logging).
-- One of 'SUBZERO', 'COLD', 'WARM', or 'HOT'.
--
-- @param   number  State
-- @return  string  State as a string
function ledge.states.tostring(state)
    for k,v in pairs(ledge.states) do
        if v == state then
            return k
        end
    end
end


-- Returns the action type as string (for logging).
-- One of 'FETCHED', 'COLLAPSED'.
--
-- @param   number  Action
-- @return  string  Action as a string
function ledge.actions.tostring(action)
    for k,v in pairs(ledge.actions) do
        if v == action then
            return k
        end
    end
end


-- Prepares the response by attempting to read from cache.
-- A skeletol response object will be returned with a state of < WARM
-- in the event of a cache miss.
function ledge.prepare()
    local response, state = ledge.cache.read()
    if not response then response = {} end -- Cache miss
    response.state = state
    ngx.ctx.response = response
end


-- Reads an item from cache
--
-- @param	string              The URI (cache key)
-- @return	table|nil, state    The response table or nil, the cache state
function ledge.cache.read()
    local ctx = ngx.ctx

    -- Fetch from Redis
    local reply = assert(redis.query_pipeline({
        { 'HGETALL', ngx.var.cache_key },
        { 'TTL', ngx.var.cache_key }
    }), "Failed to query Redis")

    -- Our cache object
    local obj = {
        header = {}
    }
    
    -- A positive TTL tells us if there's anything valid
    obj.ttl = assert(tonumber(reply[2]), "Bad TTL found for " .. ngx.var.cache_key)
    if obj.ttl < 0 then
        return nil, ledge.states.SUBZERO  -- Cache miss
    end

    assert(type(reply[1]) == 'table', 
        "Failed to collect cache data from Redis")

    local cache_parts = reply[1]
    -- The Redis reply is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        if cache_parts[i] == 'body' then
            obj.body = cache_parts[i+1]
        elseif cache_parts[i] == 'status' then
            obj.status = cache_parts[i+1]
        else
            -- Everything else will be a header, with a h: prefix.
            local _, _, header = cache_parts[i]:find('h:(.*)')
            if header then
                obj.header[header] = cache_parts[i+1]
            end
        end
    end

    event.emit("cache_accessed")

    -- Determine freshness from config.
    -- TODO: Perhaps we should be storing stale policies rather than asking config?
    if ctx.config.serve_when_stale and obj.ttl - ctx.config.serve_when_stale <= 0 then
        return obj, ledge.states.WARM
    else
        return obj, ledge.states.HOT
    end
end


-- Stores an item in cache
--
-- @param	response	            The HTTP response object to store
-- @return	boolean|nil, status     Saved state or nil, ngx.capture status on error.
function ledge.cache.save(response)
    local ctx = ngx.ctx

    if not ngx.var.request_method == "GET" or not ledge.response_is_cacheable(response) then
        return 0 -- Not cacheable, but no error
    end

    -- Our SET query
    local q = { 
        'HMSET', ngx.var.cache_key,
        'body', response.body, 
        'status', response.status,
        'uri', ngx.var.full_uri,
    }
    for header,header_value in pairs(response.header) do
        table.insert(q, 'h:'..header)
        table.insert(q, header_value)
    end

    -- Our EXPIRE query
    local expire_q = { 'EXPIRE', ngx.var.cache_key, ledge.calculate_expiry(response) }

    -- Add this to the expires queue, for cache priming and analysis.
    local expires_queue_q = { 'ZADD', 'expires_queue', response.expires, ngx.var.full_uri }

    -- Run the queries
    local reply = assert(redis.query_pipeline({ q, expire_q, expires_queue_q }), "Failed to query Redis")
    return assert(reply[1] == "OK" and reply[2] == 1 and type(reply[3]) == 'number')
end


-- Fetches a resource from the origin server.
--
-- @param	table	The URI table
-- @return	table	Response
function ledge.fetch()
    event.emit("origin_required")

    local keys = ngx.ctx.keys
    local response = ngx.ctx.response

    local ctx =  ngx.ctx

    if not ctx.config.collapse_origin_requests then
        -- We can do a straight foward fetch-and-store

        local var = ngx.var
        local uri = var.uri
        -- We need to use a relative 
        if var.args then
            uri = uri .. '?' .. var.args
        end

        -- Fetch
        local origin = ngx.location.capture(var.loc_origin..ngx.var.relative_uri, {
            method = ledge.request_method_constant(),
            body = var.request_body,
        })

        -- Could not proxy for some reason
        if not origin.status == ngx.HTTP_OK then
            return nil, origin.status
        end

        -- Save
        assert(ledge.cache.save(origin), "Could not save fetched object")

        ctx.response.status = origin.status
        ctx.response.header = origin.header
        ctx.response.body = origin.body
        ctx.response.action  = ledge.actions.FETCHED

        event.emit("origin_fetched")

        return ctx.response
    else
        assert(ngx.var.loc_wait_for_origin, "loc_wait_for_origin not defined in nginx config")

        -- Set the fetch key
        local fetch_key = ngx.var.cache_key .. ':fetch'
        local fetch = redis.query({ 'SETNX', fetch_key, '1' })
        -- TODO: Read from config
        redis.query({ 'EXPIRE', fetch_key, '10' })

        if (fetch == 1) then -- Go do the fetch
            local origin = ngx.location.capture(ngx.var.loc_origin..ngx.var.relative_uri);
            ledge.cache.save(origin)

            -- Remove the fetch and publish to waiting threads
            redis.query({ 'DEL', fetch_key })
            redis.query({ 'PUBLISH', ngx.var.cache_key, 'finished' })

            response.status = origin.status
            response.body = origin.body
            response.header = origin.header
            response.action = ledge.actions.FETCHED

            event.emit("origin_fetched")

            return response
        else
            -- This fetch is already happening Go to the collapser proxy
            local rep = ngx.location.capture(ngx.var.loc_wait_for_origin, {
                args = { channel = ngx.var.cache_key }
            });

            if (rep.status == ngx.HTTP_OK) then				
                local results = redis.parser.parse_replies(rep.body, 2)
                local messages = results[2][1] -- Second reply, body

                for k,v in pairs(messages) do
                    if (v == 'finished') then
                        -- Go get from redis
                        local response = ledge.cache.read()
                        response.status = cache.status
                        response.body = cache.body
                        response.header = cache.header
                        response.action = ledge.actions.COLLAPSED
                        return response
                    end
                end
            else
                return nil, rep.status -- Pass on the failure
            end
        end
    end
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
function ledge.background_fetch()
    redis.query({ 'PUBLISH', 'revalidate', ngx.var.full_uri })
end


-- Sends the response to the client
-- If on_before_send is defined in configuration, the response may be altered
-- by any plugins.
--
-- @param   table   Response object
-- @return  void
function ledge.send()
    event.emit("response_ready")

    local response = ngx.ctx.response
    ngx.status = response.status
    
    -- Update stats
    redis.query({'INCR', 'sledge:counter:' .. ledge.states.tostring(response.state)})

    -- Via header
    local via = '1.1 ' .. ngx.var.hostname .. ' (Ledge/' .. ledge.version .. ')'
    if  (response.header['Via'] ~= nil) then
        ngx.header['Via'] = via .. ', ' .. response.header['Via']
    else
        ngx.header['Via'] = via
    end

    -- Other headers
    for k,v in pairs(response.header) do
        ngx.header[k] = v
    end

    -- X-Cache header
    if response.state >= ledge.states.WARM then
        ngx.header['X-Cache'] = 'HIT' 
    else
        ngx.header['X-Cache'] = 'MISS'
    end

    ngx.header['X-Cache-State'] = ledge.states.tostring(response.state)
    ngx.header['X-Cache-Action'] = ledge.actions.tostring(response.action)

    -- Always ensure we send the correct length
    response.header['Content-Length'] = #response.body
    ngx.print(response.body)
    event.emit("response_sent")
    ngx.eof()
end


function ledge.request_is_cacheable() 
    local headers = ngx.req.get_headers()
    if headers['cache-control'] == 'no-cache' or headers['Pragma'] == 'no-cache' then
        return false
    end
    return true
end


-- Determines if the response can be stored, based on RFC 2616.
-- This is probably not complete.
function ledge.response_is_cacheable(response)
    local cacheable = true

    local nocache_headers = {}
    nocache_headers['Pragma'] = { 'no-cache' }
    nocache_headers['Cache-Control'] = { 
        'no-cache', 
        'must-revalidate', 
        'no-store', 
        'private' 
    }

    for k,v in pairs(nocache_headers) do
        for i,header in ipairs(v) do
            if (response.header[k] and response.header[k] == header) then
                cacheable = false
                break
            end
        end
    end

    return cacheable
end


-- Work out the valid expiry from the Expires header.
function ledge.calculate_expiry(response)
    response.ttl = 0
    if (ledge.response_is_cacheable(response)) then
        local ex = response.header['Expires']
        if ex then
            local serve_when_stale = ngx.ctx.config.serve_when_stale or 0
            response.expires = ngx.parse_http_time(ex)
            response.ttl =  (response.expires - ngx.time()) + serve_when_stale
        end
    end

    return response.ttl
end


-- Metatable
--
-- To avoid race conditions, we specify a shared metatable and detect any 
-- attempt to accidentally declare a field in this module from outside.
setmetatable(ledge, {})
getmetatable(ledge).__newindex = function(table, key, val) 
    error('Attempt to write to undeclared variable "'..key..'": '..debug.traceback()) 
end


return ledge
