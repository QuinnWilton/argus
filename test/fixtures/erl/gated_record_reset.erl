%% A record state's gate that a handler opens again (clientlib/runs.dl's
%% gated_once_site): detach sets `ref` back to undefined, and the next
%% attach monitors again.
-module(gated_record_reset).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {ref = undefined, count = 0}).

init([]) -> {ok, #state{}}.

handle_call(detach, _From, State) -> {reply, ok, State#state{ref = undefined}}.

handle_cast(attach, State = #state{ref = undefined}) ->
    erlang:monitor(process, whereis(gated_upstream)),
    {noreply, State#state{ref = make_ref()}}.
