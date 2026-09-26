%% Keeps its registrants in a field of its state record: a restart
%% starts it with none (test/soundness/coupling_test.exs).
-module(restart_record_keeper).
-behaviour(gen_server).
-export([start_link/0, register/1, init/1, handle_call/3, handle_cast/2]).

-record(state, {subs = [] :: [pid()], calls = 0 :: non_neg_integer()}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Pid) -> gen_server:call(?MODULE, {register, Pid}).

init([]) -> {ok, #state{}}.

handle_call({register, Pid}, _From, #state{subs = Subs} = State) ->
    {reply, ok, State#state{subs = [Pid | Subs]}};
handle_call(count, _From, #state{calls = N} = State) ->
    {reply, N, State}.

handle_cast(_Msg, State) -> {noreply, State}.
