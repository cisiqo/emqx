%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_routing_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/asserts.hrl").

all() ->
    [
        {group, routing_schema_v1},
        {group, routing_schema_v2},
        t_routing_schema_switch_v1,
        t_routing_schema_switch_v2
    ].

groups() ->
    TCs = [
        t_cluster_routing
    ],
    [
        {routing_schema_v1, [], TCs},
        {routing_schema_v2, [], TCs}
    ].

init_per_group(GroupName, Config) ->
    WorkDir = filename:join([?config(priv_dir, Config), ?MODULE, GroupName]),
    NodeSpecs = [
        {emqx_routing_SUITE1, #{apps => [mk_emqx_appspec(GroupName, 1)], role => core}},
        {emqx_routing_SUITE2, #{apps => [mk_emqx_appspec(GroupName, 2)], role => core}},
        {emqx_routing_SUITE3, #{apps => [mk_emqx_appspec(GroupName, 3)], role => replicant}}
    ],
    Nodes = emqx_cth_cluster:start(NodeSpecs, #{work_dir => WorkDir}),
    [{cluster, Nodes} | Config].

end_per_group(_GroupName, Config) ->
    emqx_cth_cluster:stop(?config(cluster, Config)).

init_per_testcase(TC, Config) ->
    WorkDir = filename:join([?config(priv_dir, Config), ?MODULE, TC]),
    [{work_dir, WorkDir} | Config].

end_per_testcase(_TC, _Config) ->
    ok.

mk_emqx_appspec(GroupName, N) ->
    {emqx, #{
        config => mk_config(GroupName, N),
        after_start => fun() ->
            % NOTE
            % This one is actually defined on `emqx_conf_schema` level, but used
            % in `emqx_broker`. Thus we have to resort to this ugly hack.
            emqx_config:force_put([rpc, mode], async)
        end
    }}.

mk_genrpc_appspec() ->
    {gen_rpc, #{
        override_env => [{port_discovery, stateless}]
    }}.

mk_config(GroupName, N) ->
    #{
        broker => mk_config_broker(GroupName),
        listeners => mk_config_listeners(N)
    }.

mk_config_broker(Vsn) when Vsn == routing_schema_v1; Vsn == v1 ->
    #{routing => #{storage_schema => v1}};
mk_config_broker(Vsn) when Vsn == routing_schema_v2; Vsn == v2 ->
    #{routing => #{storage_schema => v2}}.

mk_config_listeners(N) ->
    Port = 1883 + N,
    #{
        tcp => #{default => #{bind => "127.0.0.1:" ++ integer_to_list(Port)}},
        ssl => #{default => #{enable => false}},
        ws => #{default => #{enable => false}},
        wss => #{default => #{enable => false}}
    }.

%%

t_cluster_routing(Config) ->
    Cluster = ?config(cluster, Config),
    Clients = [C1, C2, C3] = lists:sort([start_client(N) || N <- Cluster]),
    Commands = [
        {fun publish/3, [C1, <<"a/b/c">>, <<"wontsee">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"wontsee">>]},
        {fun subscribe/2, [C3, <<"a/+/c/#">>]},
        {fun publish/3, [C1, <<"a/b/c">>, <<"01">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"wontsee">>]},
        {fun subscribe/2, [C1, <<"a/b/c">>]},
        {fun subscribe/2, [C2, <<"a/b/+">>]},
        {fun publish/3, [C3, <<"a/b/c">>, <<"02">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"03">>]},
        {fun publish/3, [C2, <<"a/b/c/d">>, <<"04">>]},
        {fun subscribe/2, [C3, <<"a/b/d">>]},
        {fun publish/3, [C1, <<"a/b/d">>, <<"05">>]},
        {fun unsubscribe/2, [C3, <<"a/+/c/#">>]},
        {fun publish/3, [C1, <<"a/b/c">>, <<"06">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"07">>]},
        {fun publish/3, [C2, <<"a/b/c/d">>, <<"08">>]},
        {fun unsubscribe/2, [C2, <<"a/b/+">>]},
        {fun publish/3, [C1, <<"a/b/c">>, <<"09">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"10">>]},
        {fun publish/3, [C2, <<"a/b/c/d">>, <<"11">>]},
        {fun unsubscribe/2, [C3, <<"a/b/d">>]},
        {fun unsubscribe/2, [C1, <<"a/b/c">>]},
        {fun publish/3, [C1, <<"a/b/c">>, <<"wontsee">>]},
        {fun publish/3, [C2, <<"a/b/d">>, <<"wontsee">>]}
    ],
    ok = lists:foreach(fun({F, Args}) -> erlang:apply(F, Args) end, Commands),
    _ = [emqtt:stop(C) || C <- Clients],
    Deliveries = ?drainMailbox(),
    ?assertMatch(
        [
            {pub, C1, #{topic := <<"a/b/c">>, payload := <<"02">>}},
            {pub, C1, #{topic := <<"a/b/c">>, payload := <<"06">>}},
            {pub, C1, #{topic := <<"a/b/c">>, payload := <<"09">>}},
            {pub, C2, #{topic := <<"a/b/c">>, payload := <<"02">>}},
            {pub, C2, #{topic := <<"a/b/d">>, payload := <<"03">>}},
            {pub, C2, #{topic := <<"a/b/d">>, payload := <<"05">>}},
            {pub, C2, #{topic := <<"a/b/c">>, payload := <<"06">>}},
            {pub, C2, #{topic := <<"a/b/d">>, payload := <<"07">>}},
            {pub, C3, #{topic := <<"a/b/c">>, payload := <<"01">>}},
            {pub, C3, #{topic := <<"a/b/c">>, payload := <<"02">>}},
            {pub, C3, #{topic := <<"a/b/c/d">>, payload := <<"04">>}},
            {pub, C3, #{topic := <<"a/b/d">>, payload := <<"05">>}},
            {pub, C3, #{topic := <<"a/b/d">>, payload := <<"07">>}},
            {pub, C3, #{topic := <<"a/b/d">>, payload := <<"10">>}}
        ],
        lists:sort(
            fun({pub, CL, #{payload := PL}}, {pub, CR, #{payload := PR}}) ->
                {CL, PL} < {CR, PR}
            end,
            Deliveries
        )
    ).

start_client(Node) ->
    Self = self(),
    {ok, C} = emqtt:start_link(#{
        port => get_mqtt_tcp_port(Node),
        msg_handler => #{
            publish => fun(Msg) -> Self ! {pub, self(), Msg} end
        }
    }),
    {ok, _Props} = emqtt:connect(C),
    C.

publish(C, Topic, Payload) ->
    {ok, #{reason_code := 0}} = emqtt:publish(C, Topic, Payload, 1).

subscribe(C, Topic) ->
    % NOTE: sleeping here as lazy way to wait for subscribe to replicate
    {ok, _Props, [0]} = emqtt:subscribe(C, Topic),
    ok = timer:sleep(200).

unsubscribe(C, Topic) ->
    % NOTE: sleeping here as lazy way to wait for unsubscribe to replicate
    {ok, _Props, undefined} = emqtt:unsubscribe(C, Topic),
    ok = timer:sleep(200).

%%

t_routing_schema_switch_v1(Config) ->
    t_routing_schema_switch(_From = v2, _To = v1, Config).

t_routing_schema_switch_v2(Config) ->
    t_routing_schema_switch(_From = v1, _To = v2, Config).

t_routing_schema_switch(VFrom, VTo, Config) ->
    % Start first node with routing schema VTo (e.g. v1)
    WorkDir = ?config(work_dir, Config),
    [Node1] = emqx_cth_cluster:start(
        [
            {routing_schema_switch1, #{
                apps => [mk_genrpc_appspec(), mk_emqx_appspec(VTo, 1)]
            }}
        ],
        #{work_dir => WorkDir}
    ),
    % Ensure there's at least 1 route on Node1
    C1 = start_client(Node1),
    ok = subscribe(C1, <<"a/+/c">>),
    ok = subscribe(C1, <<"d/e/f/#">>),
    % Start rest of nodes with routing schema VFrom (e.g. v2)
    [Node2, Node3] = emqx_cth_cluster:start(
        [
            {routing_schema_switch2, #{
                apps => [mk_genrpc_appspec(), mk_emqx_appspec(VFrom, 2)],
                base_port => 20000,
                join_to => Node1
            }},
            {routing_schema_switch3, #{
                apps => [mk_genrpc_appspec(), mk_emqx_appspec(VFrom, 3)],
                base_port => 20100,
                join_to => Node1
            }}
        ],
        #{work_dir => WorkDir}
    ),
    % Verify that new nodes switched to schema v1/v2 in presence of v1/v2 routes respectively
    Nodes = [Node1, Node2, Node3],
    ?assertEqual(
        [{ok, VTo}, {ok, VTo}, {ok, VTo}],
        erpc:multicall(Nodes, emqx_router, get_schema_vsn, [])
    ),
    % Wait for all nodes to agree on cluster state
    ?retry(
        500,
        10,
        ?assertMatch(
            [{ok, [Node1, Node2, Node3]}],
            lists:usort(erpc:multicall(Nodes, emqx, running_nodes, []))
        )
    ),
    % Verify that routing works as expected
    C2 = start_client(Node2),
    ok = subscribe(C2, <<"a/+/d">>),
    C3 = start_client(Node3),
    ok = subscribe(C3, <<"d/e/f/#">>),
    {ok, _} = publish(C1, <<"a/b/d">>, <<"hey-newbies">>),
    {ok, _} = publish(C2, <<"a/b/c">>, <<"hi">>),
    {ok, _} = publish(C3, <<"d/e/f/42">>, <<"hello">>),
    ?assertReceive({pub, C2, #{topic := <<"a/b/d">>, payload := <<"hey-newbies">>}}),
    ?assertReceive({pub, C1, #{topic := <<"a/b/c">>, payload := <<"hi">>}}),
    ?assertReceive({pub, C1, #{topic := <<"d/e/f/42">>, payload := <<"hello">>}}),
    ?assertReceive({pub, C3, #{topic := <<"d/e/f/42">>, payload := <<"hello">>}}),
    ?assertNotReceive(_),
    ok = emqtt:stop(C1),
    ok = emqtt:stop(C2),
    ok = emqtt:stop(C3),
    ok = emqx_cth_cluster:stop(Nodes).

%%

get_mqtt_tcp_port(Node) ->
    {_, Port} = erpc:call(Node, emqx_config, get, [[listeners, tcp, default, bind]]),
    Port.
