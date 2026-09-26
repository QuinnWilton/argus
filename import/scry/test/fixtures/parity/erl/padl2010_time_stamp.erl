%% PADL 2010, Fig. 2, right: "a function from the code of the snmp
%% application of Erlang/OTP R13B01", as the paper prints it. The figure
%% elides the record definition; the write only touches the row the read
%% counts in if the key defaults to it, so it does here. The write comes
%% after the case, not inside it: it depends on the read through NRef.
-module(padl2010_time_stamp).

-export([table_func/2]).

-record(time_stamp, {key = ref_count, data}).

table_func(_Name, _Opts) ->
    create_time_stamp_table(), ok.

create_time_stamp_table() ->
    Props = [{type, set}, {attributes, record_info(fields, time_stamp)}],
    create_table(time_stamp, Props, ram_copies, false),
    NRef =
        case mnesia:dirty_read(time_stamp, ref_count) of
            [] -> 1;
            [#time_stamp{data = Ref}] -> Ref + 1
        end,
    mnesia:dirty_write(#time_stamp{data = NRef}).

create_table(Name, Props, Storage, _Local) ->
    mnesia:create_table(Name, [{Storage, [node()]} | Props]).
