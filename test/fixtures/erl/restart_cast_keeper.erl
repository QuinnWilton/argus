%% Keeps each process that joins by a cast in a field of its state
%% record: a restart starts it with none (test/soundness/coupling_test.exs).
-module(restart_cast_keeper).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

-record(state, {members = [] :: [pid()]}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) -> {ok, #state{}}.

handle_call(count, _From, #state{members = Members} = State) ->
    {reply, length(Members), State}.

handle_cast({join, Pid}, #state{members = Members} = State) ->
    {noreply, State#state{members = [Pid | Members]}}.
