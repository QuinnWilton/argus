%% PADL 2010, Sect. 4.2: "Loops require special attention. A
%% pre-processing step detects cycles in the call graph and checks whether
%% a write built-in is followed by a read built-in in some path in that
%% cycle." The paper gives no code; this is the shape: tick/2 writes, then
%% reads, then loops, and the read decides the next iteration's write.
%% Every spawned ticker shares the one public table.
-module(padl2010_loop).

-export([start/1]).

start(N) ->
    ets:new(loop_hits, [named_table, public]),
    [spawn(fun () -> tick(loop_hits, []) end) || _ <- lists:seq(1, N)],
    ok.

tick(Tab, Seen) ->
    case Seen of
        [] -> ets:insert(Tab, {hits, 1});
        [{hits, Hits}] -> ets:insert(Tab, {hits, Hits + 1})
    end,
    receive
        stop -> ok
    after 1000 ->
        tick(Tab, ets:lookup(Tab, hits))
    end.
