use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
}

};

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    }
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 1


=== TEST 2: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}

--- request eval
["PURGE /purge_cached", "PURGE /purge_cached"]
--- no_error_log
[error]
--- response_body eval
['{"result":"purged","purge_mode":"invalidate"}',
'{"result":"already expired","purge_mode":"invalidate"}']
--- error_code eval
[200, 404]


=== TEST 3: Cache has been purged
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    }
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 3


=== TEST 4: Purge on unknown key returns 404
--- http_config eval: $::HttpConfig
--- config
location /foobar {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}

--- request
PURGE /foobar
--- no_error_log
[error]
--- response_body: {"result":"nothing to purge","purge_mode":"invalidate"}
--- error_code: 404


=== TEST 5a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    }
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 5b: Wildcard Purge
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /purge_cached*
--- wait: 1
--- no_error_log
[error]
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":\{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 5c: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5c")
    }
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5c


=== TEST 5d: Cache has been purged without args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5d")
    }
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 5d


=== TEST 6a: Purge everything
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /purge_c*
--- wait: 3
--- error_code: 200
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":\{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- no_error_log
[error]


=== TEST 6: Cache keys have been collected by Redis
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        local key_chain = handler:cache_key_chain()

        local num_entities, err = redis:scard(key_chain.entities)
        ngx.say("entities: ", num_entities)
    }
}
--- request
GET /purge_cached
--- no_error_log
[error]
--- response_body
entities: 1


=== TEST 7a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    }
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 7b: Wildcard Purge, mid path (no match due to args)
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /purge_ca*ed
--- wait: 1
--- no_error_log
[error]
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":\{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 7c: Confirm purge did nothing
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 8a: Prime another key - with keep_cache_for set
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_8 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8")
    }
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8


=== TEST 8b: Wildcard Purge (200)
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8 {
    content_by_lua_block {
        require("ledge").create_handler({
            keyspace_scan_count = 1,
        }):run()
    }
}
--- request
PURGE /purge_cached_8*
--- wait: 1
--- no_error_log
[error]
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":\{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 8d: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_8 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8c")
    }
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8c
--- error_code: 200


=== TEST 9a: Prime another key
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_9 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9: ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
Cookie: primed
--- request
GET /purge_cached_9_prx
--- no_error_log
[error]
--- response_body
TEST 9: primed


=== TEST 9b: Purge with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_9 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9 Revalidated: ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_9_prx
--- wait: 2
--- no_error_log
[error]
--- response_body_like: \{"result":"purged","qless_job":\{"klass":"ledge\.jobs\.revalidate","jid":"[a-f0-9]{32}","options":\{"tags":\["revalidate"\],"jid":"[a-z0-f]{32}","priority":4}},"purge_mode":"revalidate"}
--- error_code: 200


=== TEST 9c: Confirm cache was revalidated
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /purge_cached_9_prx
--- wait: 3
--- no_error_log
[error]
--- response_body
TEST 9 Revalidated: primed


=== TEST 10a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_10 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 10: ", ngx.req.get_uri_args()["a"], " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
Cookie: primed
--- request eval
[ "GET /purge_cached_10_prx?a=1", "GET /purge_cached_10_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "TEST 10: 1 primed", "TEST 10: 2 primed" ]


=== TEST 10b: Wildcard purge with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_10 {
    rewrite ^(.*)$ $1_origin break;
    content_by_lua_block {
        local a = ngx.req.get_uri_args()["a"]
        ngx.log(ngx.DEBUG, "TEST 10 Revalidated: ", a, " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_10_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[0-9a-f]{32}","options":\{"tags":\["purge"\],"jid":"[0-9a-f]{32}","priority":5}},"purge_mode":"revalidate"}
--- error_log
TEST 10 Revalidated: 1 primed
TEST 10 Revalidated: 2 primed
--- error_code: 200


=== TEST 11a: Prime a key
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_11 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 11")
    }
}
--- request
GET /purge_cached_11_prx
--- no_error_log
[error]
--- response_body: TEST 11


=== TEST 11b: Purge with X-Purge: delete
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_11_prx
--- no_error_log
[error]
--- response_body: {"result":"deleted","purge_mode":"delete"}
--- error_code: 200


=== TEST 11c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_11 {
    content_by_lua_block {
        ngx.print("ORIGIN")
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /purge_cached_11_prx
--- response_body: ORIGIN
--- no_error_log
[error]
--- error_code: 200


=== TEST 12a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_12 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 12: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
[ "GET /purge_cached_12_prx?a=1", "GET /purge_cached_12_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "TEST 12: 1", "TEST 12: 2" ]


=== TEST 12b: Wildcard purge with X-Purge: delete
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_12_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[0-9a-f]{32}","options":\{"tags":\["purge"\],"jid":"[0-9a-f]{32}","priority":5}},"purge_mode":"delete"}
--- error_code: 200


=== TEST 12c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_12 {
    content_by_lua_block {
        ngx.print("ORIGIN: ", ngx.req.get_uri_args()["a"])
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request eval
[ "GET /purge_cached_12_prx?a=1", "GET /purge_cached_12_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "ORIGIN: 1", "ORIGIN: 2" ]


=== TEST 13a: Prime two keys and break them
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local sabotage = ngx.req.get_uri_args()["sabotage"]
        if sabotage then
            -- Set query string to match original request
            ngx.req.set_uri_args({a=1})

            local redis = require("ledge").create_redis_connection()
            local handler = require("ledge").create_handler()
            local key_chain = handler:cache_key_chain()

            if sabotage == "uri" then
                redis:hdel(key_chain.main, "uri")
                ngx.print("Sabotaged: uri")
            elseif sabotage == "body" then
                handler.storage = require("ledge").create_storage_connection()

                handler.storage:delete(redis:hget(key_chain.main, entity))

                ngx.print("Sabotaged: body storage")
            end
        else
            require("ledge").create_handler():run()
        end
    }
}
location /purge_cached_13 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 13: ", ngx.req.get_uri_args()["a"], " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
Cookie: primed
--- request eval
[ "GET /purge_cached_13_prx?a=1",
"GET /purge_cached_13_prx?a=2",
"GET /purge_cached_13_prx?a=1&sabotage=body",
"GET /purge_cached_13_prx?a=1&sabotage=uri" ]
--- no_error_log
[error]
--- response_body_like eval
[ "TEST 13: 1 primed",
 "TEST 13: 2 primed",
 "Sabotaged: body storage",
 "Sabotaged: uri" ]


=== TEST 13b: Wildcard purge broken entry with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_13 {
    rewrite ^(.*)$ $1_origin break;
    content_by_lua_block {
        local a = ngx.req.get_uri_args()["a"]
        ngx.log(ngx.DEBUG, "TEST 13 Revalidated: ", a, " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_13_prx?*
--- wait: 2
--- error_log
TEST 13 Revalidated: 2 primed
--- response_body_like: \{"result":"scheduled","qless_job":\{"klass":"ledge\.jobs\.purge","jid":"[0-9a-f]{32}","options":\{"tags":\["purge"\],"jid":"[0-9a-f]{32}","priority":5}},"purge_mode":"revalidate"}
--- error_code: 200