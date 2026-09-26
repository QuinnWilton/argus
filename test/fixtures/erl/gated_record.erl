%% A record state's field as a gate (clientlib/runs.dl's gated_once_site):
%% attach monitors while `ref = undefined`, and sets a fresh ref, which no
%% atom is. Quiet: the monitor is taken once per incarnation.
-module(gated_record).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {ref = undefined, count = 0}).

init([]) -> {ok, #state{}}.

handle_call(count, _From, State = #state{count = N}) -> {reply, N, State}.

handle_cast(attach, State = #state{ref = undefined}) ->
    erlang:monitor(process, whereis(gated_upstream)),
    {noreply, State#state{ref = make_ref()}}.
