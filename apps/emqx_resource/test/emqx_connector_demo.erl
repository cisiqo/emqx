%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_connector_demo).

-include_lib("typerefl/include/types.hrl").

-behaviour(emqx_resource).

%% callbacks of behaviour emqx_resource
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_get_status/2
]).

-export([counter_loop/1]).

%% callbacks for emqx_resource config schema
-export([roots/0]).

roots() ->
    [
        {name, fun name/1},
        {register, fun register/1}
    ].

name(type) -> atom();
name(required) -> true;
name(_) -> undefined.

register(type) -> boolean();
register(required) -> true;
register(default) -> false;
register(_) -> undefined.

callback_mode() -> always_sync.

on_start(_InstId, #{create_error := true}) ->
    error("some error");
on_start(InstId, #{name := Name, stop_error := true} = Opts) ->
    Register = maps:get(register, Opts, false),
    {ok, Opts#{
        id => InstId,
        stop_error => true,
        pid => spawn_counter_process(Name, Register)
    }};
on_start(InstId, #{name := Name} = Opts) ->
    Register = maps:get(register, Opts, false),
    {ok, Opts#{
        id => InstId,
        pid => spawn_counter_process(Name, Register)
    }}.

on_stop(_InstId, #{stop_error := true}) ->
    {error, stop_error};
on_stop(_InstId, #{pid := Pid}) ->
    erlang:exit(Pid, shutdown),
    ok.

on_query(_InstId, get_state, State) ->
    {ok, State};
on_query(_InstId, get_state_failed, State) ->
    {error, State};
on_query(_InstId, {inc_counter, N}, #{pid := Pid}) ->
    Pid ! {inc, N},
    ok;
on_query(_InstId, get_counter, #{pid := Pid}) ->
    ReqRef = make_ref(),
    From = {self(), ReqRef},
    Pid ! {From, get},
    receive
        {ReqRef, Num} -> {ok, Num}
    after 1000 ->
        {error, timeout}
    end.

on_batch_query(InstId, BatchReq, State) ->
    %% Requests can be either 'get_counter' or 'inc_counter', but cannot be mixed.
    case hd(BatchReq) of
        {inc_counter, _} ->
            batch_inc_counter(InstId, BatchReq, State);
        get_counter ->
            batch_get_counter(InstId, State)
    end.

batch_inc_counter(InstId, BatchReq, State) ->
    TotalN = lists:foldl(
        fun
            ({inc_counter, N}, Total) ->
                Total + N;
            (Req, _Total) ->
                error({mixed_requests_not_allowed, {inc_counter, Req}})
        end,
        0,
        BatchReq
    ),
    on_query(InstId, {inc_counter, TotalN}, State).

batch_get_counter(InstId, State) ->
    on_query(InstId, get_counter, State).

on_get_status(_InstId, #{health_check_error := true}) ->
    disconnected;
on_get_status(_InstId, #{pid := Pid}) ->
    timer:sleep(300),
    case is_process_alive(Pid) of
        true -> connected;
        false -> disconnected
    end.

spawn_counter_process(Name, Register) ->
    Pid = spawn_link(?MODULE, counter_loop, [#{counter => 0}]),
    true = maybe_register(Name, Pid, Register),
    Pid.

counter_loop(#{counter := Num} = State) ->
    NewState =
        receive
            {inc, N} ->
                #{counter => Num + N};
            {{FromPid, ReqRef}, get} ->
                FromPid ! {ReqRef, Num},
                State
        end,
    counter_loop(NewState).

maybe_register(Name, Pid, true) ->
    ct:pal("---- Register Name: ~p", [Name]),
    ct:pal("---- whereis(): ~p", [whereis(Name)]),
    erlang:register(Name, Pid);
maybe_register(_Name, _Pid, false) ->
    true.
