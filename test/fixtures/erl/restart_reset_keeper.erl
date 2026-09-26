%% Caches definitions; `invalidate` sets them back to `none`, the value
%% init/1 starts them at.
-module(restart_reset_keeper).
-behaviour(gen_server).
-export([start_link/0, invalidate/0, init/1, handle_call/3, handle_cast/2]).

-record(state, {defs = none :: none | map(), hits = 0 :: non_neg_integer()}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

invalidate() -> gen_server:cast(?MODULE, invalidate).

init([]) -> {ok, #state{}}.

handle_call(defs, _From, #state{defs = Defs} = State) -> {reply, Defs, State}.

handle_cast(invalidate, State) -> {noreply, State#state{defs = none}}.
