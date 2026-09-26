%% The census's comprehension, its recursion through a helper: the
%% comprehension calls level/2, which calls names/2 again with the atom
%% the comprehension minted.
-module(census_tree_levels).
-export([names/2]).

names(Parent, Kids) ->
    [level(list_to_atom(atom_to_list(Parent) ++ "." ++ atom_to_list(C)), Sub)
     || {C, Sub} <- Kids].

level(Name, Sub) -> {Name, names(Name, Sub)}.
