%% Quiet: a comprehension that suffixes each atom of its list once. Its
%% atoms are bounded by the atoms it is handed, and none comes back to it:
%% the comprehension's own loop walks the list.
-module(census_flat_names).
-export([names/1]).

names(Atoms) -> [list_to_atom(atom_to_list(A) ++ "_worker") || A <- Atoms].
