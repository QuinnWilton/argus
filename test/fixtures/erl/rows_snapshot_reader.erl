%% Callers' reads of the tables the application-root fixtures keep. The
%% root supervisor's table lives as long as its application, so no read
%% of it meets it gone; each other owner has a restart of its own (a
%% supervisor another tree also starts, one no Application starts, one
%% nothing starts, a worker start/2 starts directly) and its read is
%% reported.
-module(rows_snapshot_reader).

-export([root/1, dual/1, fake/1, branch/1, worker/1]).

root(K) -> ets:lookup(root_app_snapshot, K).

dual(K) -> ets:lookup(dual_snapshot, K).

fake(K) -> ets:lookup(fake_root_snapshot, K).

branch(K) -> ets:lookup(branch_snapshot, K).

worker(K) -> ets:lookup(worker_owner_tab, K).
