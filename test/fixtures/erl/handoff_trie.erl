%% vernemq's vmq_reg_ordered_trie, in its own shape: a record state that
%% starts `status = init`, a loader init/1 spawns whose last act reports
%% `subscribers_loaded` to its starter, updates queued while the status
%% is init and served by a clause that takes any state after it, the
%% report's clause draining the queue and setting the status to ready,
%% and a test hook, `{event, Event}`, that serves whatever the status.
%% handoff_trie_client is the program's client: nothing asks for the hook.
-module(handoff_trie).
-behaviour(gen_server).

-export([start_link/0, update/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {status = init, queue = []}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

update(Topic, Delta) -> gen_server:call(?MODULE, {update, Topic, Delta}).

init([]) ->
    _ = ets:new(handoff_trie_topics, [named_table, public]),
    Self = self(),
    spawn_link(fun() ->
                       ok = lists:foreach(fun add/1, stored()),
                       Self ! subscribers_loaded
               end),
    {ok, #state{}}.

handle_call({event, Topic, Delta}, _From, State = #state{}) ->
    bump(Topic, Delta),
    {reply, ok, State};
handle_call({update, _, _} = Update, _From, State = #state{status = init, queue = Q}) ->
    {reply, ok, State#state{queue = [Update | Q]}};
handle_call({update, Topic, Delta}, _From, State) ->
    bump(Topic, Delta),
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(subscribers_loaded, State = #state{queue = Q}) ->
    lists:foreach(fun({update, T, D}) -> bump(T, D) end, lists:reverse(Q)),
    {noreply, State#state{status = ready, queue = []}};
handle_info(_Info, State) ->
    {noreply, State}.

stored() -> persistent_term:get(handoff_trie_stored, []).

add(Topic) -> bump(Topic, 1).

bump(Topic, Delta) ->
    case ets:lookup(handoff_trie_topics, Topic) of
        [{Topic, N}] -> ets:insert(handoff_trie_topics, {Topic, N + Delta});
        [] -> ets:insert(handoff_trie_topics, {Topic, Delta})
    end.
