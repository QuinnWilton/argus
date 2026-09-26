%% A connection machine (state_functions) that, like ssl's tls_connection,
%% hands its connected state's events to the shared connection machine
%% (excl_state_machine_common), whose returns name this machine's states:
%% its renegotiate clause moves connected back to hello. connected has a
%% way out, through the module it delegates to, and is not terminal.
%% Pins an exclusion no evaluation program exercises (census 2026-09-26);
%% see test/exclusions/state_machine_test.exs.
-module(excl_state_machine_hello).
-behaviour(gen_statem).
-export([start_link/1, init/1, callback_mode/0, hello/3, connected/3]).

start_link(Opts) -> gen_statem:start_link(?MODULE, Opts, []).
callback_mode() -> state_functions.
init(Opts) -> {ok, hello, Opts}.

hello(cast, {server_hello, Params}, Data) ->
    {next_state, connected, Data#{params => Params}};
hello(EventType, Event, Data) ->
    excl_state_machine_common:handle_common_event(EventType, Event, hello, Data).

connected(EventType, Event, Data) ->
    excl_state_machine_common:handle_connected(EventType, Event, ?MODULE, Data).
