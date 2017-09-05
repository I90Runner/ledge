use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = TEST_NGINX_PORT,
    })

}

}; # HttpConfig

no_long_string();
#no_diff();
run_tests();


__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = assert(require("ledge.esi.processor_1_0"),
            "module should load without errors")

        local processor = processor.new(require("ledge").create_handler())
        assert(processor, "processor_1_0.new should return positively")

        ngx.say("OK")
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
OK

=== TEST 2: esi_eval_var - QUERY STRING
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"QUERY_STRING", nil, "default", "default_quoted" },
            {"QUERY_STRING", nil, nil, "default_quoted" },
            {"QUERY_STRING", "test_param", "default", "default_quoted" },
            {"QUERY_STRING", "test_param", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?test_param=test",
  "GET /t?other_param=test"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
default
default_quoted
",

"test_param=test
test_param=test
test
test
",

"other_param=test
other_param=test
default
default_quoted
",
]


=== TEST 3: esi_eval_var - HTTP header
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_X_TEST", nil, "default", "default_quoted" },
            {"HTTP_X_TEST", nil, nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"X-Dummy: foo",
"X-TEST: test_val"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
",

"test_val
test_val
",
]

=== TEST 4: esi_eval_var - Duplicate HTTP header
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_X_TEST", nil, "default", "default_quoted" },
            {"HTTP_X_TEST", nil, nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"X-Dummy: foo",

"X-TEST: test_val
X-TEST: test_val2"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
",

"test_val, test_val2
test_val, test_val2
",
]

=== TEST 5: esi_eval_var - Cookie
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_COOKIE", nil, "default", "default_quoted" },
            {"HTTP_COOKIE", "test_cookie", "default", "default_quoted" },
            {"HTTP_COOKIE", "test_cookie", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"",
"Cookie: none=here",
"Cookie: test_cookie=my_cookie"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"none=here
default
default_quoted
",

"test_cookie=my_cookie
my_cookie
my_cookie
",
]

=== TEST 6: esi_eval_var - Accept-Lang
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", nil, "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", "en", "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", "de", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"",

"Accept-Language: en-gb",

"Accept-Language: en-us, blah",

"Accept-Language: en-gb
Accept-Language: test"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"en-gb
true
false
",

"en-us, blah
true
false
",

"en-gb, test
true
false
",
]

=== TEST 7: esi_eval_var - ESI_ARGS
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        -- Fake ESI args
        require("ledge.esi").filter_esi_args(
            require("ledge").create_handler()
        )
        ngx.log(ngx.DEBUG, require("cjson").encode(ngx.ctx.__ledge_esi_args))

        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"ESI_ARGS", nil, "default", "default_quoted" },
            {"ESI_ARGS", "var1", "default", "default_quoted" },
            {"ESI_ARGS", "var2", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?esi_var1=test1&esi_var2=test2&foo=bar",
  "GET /t?esi_var2=test2&foo=bar",
  "GET /t?esi_var1=test1&esi_other_var=foo&foo=bar",
  "GET /t?esi_var1=test1&esi_var1=test2&foo=bar",
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"esi_var2=test2&esi_var1=test1
test1
test2
",

"esi_var2=test2
default
test2
",

"esi_other_var=foo&esi_var1=test1
test1
default_quoted
",

"esi_var1=test1&esi_var1=test2
test1,test2
default_quoted
",
]

=== TEST 8: esi_eval_var - custom vars
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        ngx.ctx.__ledge_esi_custom_variables = ngx.req.get_uri_args() or {}

        if ngx.ctx.__ledge_esi_custom_variables["empty"] then
            ngx.ctx.__ledge_esi_custom_variables = {}
        else
            ngx.ctx.__ledge_esi_custom_variables["deep"] = {["table"] = "value!"}
        end

        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"var1", nil, "default", "default_quoted" },
            {"var2", nil, nil, "default_quoted" },
            {"var1", "subvar", nil, "default_quoted" },
            {"deep", "table", "default", "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?var1=test1&var2=test2",
  "GET /t?var2=test2",
  "GET /t?empty=true",
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
default_quoted
value!
",

"test1
test2
default_quoted
value!
",

"default
test2
default_quoted
value!
",

"default
default_quoted
default_quoted
default
",
]