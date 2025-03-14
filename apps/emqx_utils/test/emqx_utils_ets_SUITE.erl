%%--------------------------------------------------------------------
%% Copyright (c) 2018-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_utils_ets_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(TAB, ?MODULE).

all() -> emqx_common_test_helpers:all(?MODULE).

t_new(_) ->
    ok = emqx_utils_ets:new(?TAB),
    ok = emqx_utils_ets:new(?TAB, [{read_concurrency, true}]),
    ?assertEqual(?TAB, ets:info(?TAB, name)).

t_lookup_value(_) ->
    ok = emqx_utils_ets:new(?TAB, []),
    true = ets:insert(?TAB, {key, val}),
    ?assertEqual(val, emqx_utils_ets:lookup_value(?TAB, key)),
    ?assertEqual(undefined, emqx_utils_ets:lookup_value(?TAB, badkey)).

t_delete(_) ->
    ok = emqx_utils_ets:new(?TAB, []),
    ?assertEqual(?TAB, ets:info(?TAB, name)),
    ok = emqx_utils_ets:delete(?TAB),
    ok = emqx_utils_ets:delete(?TAB),
    ?assertEqual(undefined, ets:info(?TAB, name)).
