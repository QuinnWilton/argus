%% The hello machine of excl_state_machine_hello with a connected state
%% that keeps its state on every event, delegating nothing: nothing takes
%% it back to hello or stops it, a dead end once entered. What the
%% delegating machine is not.
-module(excl_state_machine_stuck).
-behaviour(gen_statem).
-export([start_link/1, init/1, callback_mode/0, hello/3, connected/3]).

start_link(Opts) -> gen_statem:start_link(?MODULE, Opts, []).
callback_mode() -> state_functions.
init(Opts) -> {ok, hello, Opts}.

hello(cast, {server_hello, Params}, Data) ->
    {next_state, connected, Data#{params => Params}};
hello(_EventType, _Event, Data) ->
    {keep_state, Data}.

connected(_EventType, _Event, Data) ->
    {keep_state, Data}.
