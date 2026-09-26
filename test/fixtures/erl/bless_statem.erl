%% group's shape: a gen_statem that declares no behaviour and starts
%% itself with gen_statem:start/3. Its catch-all state clause takes a
%% call other than ping and never replies: a finding the statem rules
%% make only once they read it as a gen_statem.
-module(bless_statem).

-export([start/0, callback_mode/0, init/1, idle/3]).

start() ->
    gen_statem:start(?MODULE, [], []).

callback_mode() ->
    state_functions.

init([]) ->
    {ok, idle, #{}}.

idle({call, From}, ping, Data) ->
    {keep_state, Data, [{reply, From, pong}]};
idle(_Type, _Event, Data) ->
    {keep_state, Data}.
