%% The helper whose tables the root supervisor's tree keeps, read by callers.
-module(rows_root_tabs).

-export([create/0, lookup/1, keeper/1, child/1]).

create() ->
    ets:new(rows_root_tab, [named_table, public]).

lookup(K) -> ets:lookup(rows_root_tab, K).

keeper(K) -> ets:lookup(rows_root_keeper, K).

child(K) -> ets:lookup(rows_root_child_tab, K).
