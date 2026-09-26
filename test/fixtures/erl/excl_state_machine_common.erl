%% The shared connection machine (ssl_gen_statem's role): a gen_statem
%% module itself, whose helpers return transitions on behalf of the
%% protocol machine that delegates to it (excl_state_machine_hello).
-module(excl_state_machine_common).
-behaviour(gen_statem).
-export([start_link/1, init/1, callback_mode/0, handle_common_event/4, handle_connected/4, idle/3]).

start_link(Opts) -> gen_statem:start_link(?MODULE, Opts, []).
callback_mode() -> state_functions.
init(Opts) -> {ok, idle, Opts}.
idle(_T, _E, Data) -> {keep_state, Data}.

handle_common_event(info, {tcp_closed, _}, _State, Data) ->
    {stop, normal, Data};
handle_common_event(_T, _E, _State, Data) ->
    {keep_state, Data}.

handle_connected(cast, renegotiate, _Mod, Data) ->
    {next_state, hello, Data};
handle_connected(info, {tcp_closed, _}, _Mod, Data) ->
    {stop, normal, Data};
handle_connected(_T, _E, _Mod, Data) ->
    {keep_state, Data}.
