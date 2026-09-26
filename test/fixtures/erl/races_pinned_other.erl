%% The key matched out of a row another lookup found names that lookup's
%% key: the delete below is of Other's row, which the lookup of Node did
%% not read.
-module(races_pinned_other).
-export([start/0, add/2, move/2]).

start() -> ets:new(races_pinned_others, [named_table, public]).

add(Node, Owner) -> ets:insert(races_pinned_others, {Node, Owner}).

move(Node, Other) ->
    case ets:lookup(races_pinned_others, Node) of
        [] ->
            ok;
        [_] ->
            [{Key, Owner}] = ets:lookup(races_pinned_others, Other),
            true = ets:delete(races_pinned_others, Key),
            Owner ! moved,
            ok
    end.
