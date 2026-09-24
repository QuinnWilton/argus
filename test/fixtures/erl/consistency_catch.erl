%% failure.inconsistent_handling over Erlang's `catch Expr`, which takes
%% every class. Table `ec`: three sites guard ets:update_counter/3 with
%% the old `catch` form and d/1 calls it bare, the deviant (snmpm_config
%% and snmpa_usm keep this convention). Table `mx`: three sites guard it
%% with try and one with catch; all four are guarded, and none deviates.
-module(consistency_catch).

-export([a/1, b/1, c/1, d/1, m1/1, m2/1, m3/1, m4/1]).

a(K) -> case catch ets:update_counter(ec, K, 1) of {'EXIT', _} -> 0; N -> N end.
b(K) -> case catch ets:update_counter(ec, K, 2) of {'EXIT', _} -> 0; N -> N end.
c(K) -> case catch ets:update_counter(ec, K, 3) of {'EXIT', _} -> 0; N -> N end.
d(K) -> ets:update_counter(ec, K, 4).

m1(K) -> try ets:update_counter(mx, K, 1) catch error:badarg -> 0 end.
m2(K) -> try ets:update_counter(mx, K, 2) catch error:badarg -> 0 end.
m3(K) -> try ets:update_counter(mx, K, 3) catch error:badarg -> 0 end.
m4(K) -> case catch ets:update_counter(mx, K, 4) of {'EXIT', _} -> 0; N -> N end.
