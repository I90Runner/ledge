local pcall, tonumber, tostring, pairs =
    pcall, tonumber, tostring, pairs

local ngx_null = ngx.null
local ngx_time = ngx.time
local ngx_md5 = ngx.md5

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local cjson_encode = require("cjson").encode


local _M = {
    _VERSION = '1.28.3',
}


local function create_purge_response(purge_mode, result, qless_job)
    local d = {
        purge_mode = purge_mode,
        result = result,
    }
    if qless_job then d.qless_job = qless_job end

    local ok, json = pcall(cjson_encode, d)

    if not ok then
        return nil, json
    else
        return json
    end
end
_M.create_purge_response = create_purge_response


-- Expires the keys in key_chain and reduces the ttl in storage
-- TODO review this for error cases etc
local function expire_keys(redis, storage, key_chain, entity_id)
    local exists, err = redis:exists(key_chain.main)
    if exists == 1 then
        local time = ngx_time()
        local expires, err = redis:hget(key_chain.main, "expires")
        if not expires or expires == ngx_null then
            return nil, "could not determine existing expiry: " .. (err or "")
        end

        -- If expires is in the past then this key is stale. Nothing to do here.
        if tonumber(expires) <= time then
            return false, nil
        end

        local ttl, err = redis:ttl(key_chain.main)
        if not ttl or ttl == ngx_null then
            return nil, "count not determine exsiting ttl: " .. (err or "")
        end

        local ttl_reduction = expires - time
        if ttl_reduction < 0 then ttl_reduction = 0 end

        redis:multi()

        -- Set the expires field of the main key to the new time, to control
        -- its validity.
        redis:hset(key_chain.main, "expires", tostring(time - 1))

        -- Set new TTLs for all keys in the key chain
        key_chain.fetching_lock = nil -- this looks after itself
        for _,key in pairs(key_chain) do
            redis:expire(key, ttl - ttl_reduction)
        end

        storage:set_ttl(entity_id, ttl - ttl_reduction)

        local ok, err = redis:exec()
        if err then
            return nil, err
        else
            return true, nil
        end
    else
        return false, nil
    end
end
_M.expire_keys = expire_keys


-- Purges the cache item according to purge_mode which defaults to "invalidate".
-- If there's nothing to do we return false which results in a 404.
-- @param   table   handler instance
-- @param   string  "invalidate" | "delete" | "revalidate
-- @return  boolean success
-- @return  string  message
local function purge(handler, purge_mode)
    local redis = handler.redis
    local storage = handler.storage
    local key_chain = handler:cache_key_chain()
    local entity_id, err = redis:hget(key_chain.main, "entity")

    -- We 404 if we have nothing
    if not entity_id or entity_id == ngx_null
        or not storage:exists(entity_id) then

        return false, "nothing to purge"
    end

    -- Delete mode overrides everything else, since you can't revalidate
    if purge_mode == "delete" then
        local res, err = handler:delete_from_cache()
        if not res then
            return nil, err
        else
            return true, "deleted"
        end
    end

    -- If we're revalidating, fire off the background job
    local job
    if purge_mode == "revalidate" then
        job = handler:revalidate_in_background(false)
    end

    -- Invalidate the keys
    local entity_id = handler:entity_id(key_chain)
    local ok, err = expire_keys(redis, storage, key_chain, entity_id)

    local result
    if not ok and err then
        return nil, err

    elseif not ok then
        return false, "already expired"

    elseif ok then
        return true, "purged", job

    end
end
_M.purge = purge


local function purge_in_background(handler, purge_mode)
    local key_chain = handler:cache_key_chain()

    local job, err = handler:put_background_job(
        "ledge_purge",
        "ledge.jobs.purge", {
        key_chain = key_chain,
        keyspace_scan_count = handler.config.keyspace_scan_count,
        purge_mode = purge_mode,
    }, {
        jid = ngx_md5("purge:" .. tostring(key_chain.root)),
        tags = { "purge" },
        priority = 5,
    })

    -- Create a JSON payload for the response
    handler.response:set_body(create_purge_response(
        purge_mode,
        "scheduled",
        job
    ))

    return true
end
_M.purge_in_background = purge_in_background


return setmetatable(_M, fixed_field_metatable)
