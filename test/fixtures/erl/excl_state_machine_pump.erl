%% A pump machine whose idle state (the initial one) answers status calls
%% and never leaves: the start transition to running was forgotten, so
%% running is dead code (reported unreachable) and the machine is a
%% one-state server resting where it starts, which is no terminal state.
%% running's way back to idle is an incoming edge of the initial state,
%% not a reason to call idle a dead end.
%% Pins an exclusion no evaluation program exercises (census 2026-09-26);
%% see test/exclusions/state_machine_test.exs.
-module(excl_state_machine_pump).
-behaviour(gen_statem).
-export([start_link/0, init/1, callback_mode/0, idle/3, running/3]).

start_link() -> gen_statem:start_link(?MODULE, [], []).
callback_mode() -> state_functions.
init([]) -> {ok, idle, #{runs => 0}}.

idle({call, From}, status, Data) ->
    {keep_state, Data, [{reply, From, idle}]};
idle(_EventType, _Event, Data) ->
    {keep_state, Data}.

running(cast, stop, Data = #{runs := N}) ->
    {next_state, idle, Data#{runs := N + 1}};
running({call, From}, status, Data) ->
    {keep_state, Data, [{reply, From, running}]};
running(_EventType, _Event, Data) ->
    {keep_state, Data}.
