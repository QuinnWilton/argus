%% The exclusion census's hole (docs/design/exclusions.md): names each
%% node of a caller's tree after its parent (a, a.b, a.b.c), as a library
%% registering one process per node would. Every level is an atom made of
%% the atom the level above minted, so a caller's deep tree of one
%% existing atom ({b, [{b, [...]}]}) mints a new atom per level. The
%% comprehension's function calls names/2 again: a way back, not only the
%% loop the comprehension compiles to. Asserted by
%% test/soundness/unsafe_input_test.exs.
-module(census_tree_names).
-export([names/2]).

names(Parent, Kids) ->
    [begin
         Name = list_to_atom(atom_to_list(Parent) ++ "." ++ atom_to_list(C)),
         {Name, names(Name, Sub)}
     end
     || {C, Sub} <- Kids].
