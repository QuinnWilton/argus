-module(soundness_gs2trap).
-behaviour(soundness_wrapper).
%% rabbit's gen_server2 hands a trapped {'EXIT', ...} to handle_info/2,
%% as gen_server does. This server traps exits and defines no
%% handle_info/2: the wrapper's default for a missing handle_info crashes
%% or logs, and the parent's shutdown signal is never acted on.
%% (Review 2, item 9: 98cfdb25 asked only of a listed GenServer.)
-export([init/1, handle_call/3, handle_cast/2]).

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call(get, _From, S) -> {reply, S, S}.

handle_cast({put, K, V}, S) -> {noreply, S#{K => V}}.
