%% Presence-only bitmap storage. Slots are dense, exact manifest identities.
-module(efz_cov_bitmap).
-export([check_capacity/2, prepare/2, release/1, valid_schema/1, valid_schema/2, open/1,
         attach/1, hit/2, snapshot/1, snapshot_bits/1, close/1, reset/1,
         clear_quiescent/1, new_global/1, unseen_bits/2, merge_bits/2,
         decode/2, global_snapshot/2, fingerprint/1, memory/1, cas_word/4,
         allocate/1, open/2, seal/1, has_new/2, unseen_sealed/2,
         merge_sealed/2, count_sealed/1, diagnostic_snapshot/1]).

-opaque schema() :: map().
-opaque context() :: {efz_context, 1, reference(),
                      {bitmap, schema(), atomics:atomics_ref(), atomics:atomics_ref()}, pid()}.
-opaque snapshot() :: {efz_bitmap_snapshot, 1, binary(), binary()}.
-export_type([schema/0, context/0, snapshot/0]).

check_capacity(Manifests, Bits) when is_integer(Bits), Bits > 0, Bits rem 64 =:= 0 ->
    case validate_manifests(Manifests) of
        {ok, Ids, _} when length(Ids) =< Bits -> ok;
        {ok, Ids, _} -> {error, {bitmap_capacity_exceeded,
                                   #{required_bits => length(Ids), configured_bits => Bits}}};
        Error -> Error
    end;
check_capacity(_, _) -> {error, invalid_bitmap_capacity}.

prepare(Manifests, Bits) ->
    case check_capacity(Manifests, Bits) of
        ok ->
            {ok, Ids, Builds} = validate_manifests(Manifests),
            Canonical = [canonical(Id) || Id <- Ids],
            Fingerprint = crypto:hash(sha256, term_to_binary(
                {efz_bitmap, 1, clause_outcome_probe, 1, 1, Bits, Canonical},
                [deterministic])),
            Table = ets:new(efz_bitmap_slots, [set, protected, {read_concurrency, true}]),
            true = ets:insert(Table, [{'$efz_bitmap_schema', Fingerprint} |
                [{Id, Slot} || {Id, Slot} <- lists:zip(Ids, lists:seq(0, length(Ids)-1))]]),
            {ok, #{kind => efz_bitmap_schema, version => 1, table => Table,
                   owner => self(), ids => list_to_tuple(Ids), fingerprint => Fingerprint,
                   capacity => Bits, builds => Builds}};
        Error -> Error
    end.

validate_manifests(Manifests) when is_list(Manifests), Manifests =/= [] ->
    case [Error || M <- Manifests, (Error = efz_cov_manifest:validate(M)) =/= ok] of
        [] ->
            Builds = maps:from_list([{maps:get(module, M), maps:get(build_id, M)} || M <- Manifests]),
            Ids = lists:append([efz_cov_manifest:identities(M) || M <- Manifests]),
            case {map_size(Builds) =:= length(Manifests),
                  length(lists:usort(Ids)) =:= length(Ids)} of
                {false, _} -> {error, duplicate_selected_module};
                {_, false} -> {error, invalid_or_duplicate_probe};
                {true, true} -> {ok, lists:sort(fun(A, B) -> canonical(A) =< canonical(B) end,
                                        Ids), Builds}
            end;
        Errors -> {error, {invalid_manifests, Errors}}
    end;
validate_manifests(_) -> {error, automatic_coverage_requires_manifests}.

canonical({Module, Build, Probe}) -> {atom_to_binary(Module, utf8), Build, Probe}.

valid_schema(#{kind := efz_bitmap_schema, version := 1, table := T,
               owner := Owner, fingerprint := F, ids := Ids, capacity := Bits})
  when is_pid(Owner), is_binary(F), byte_size(F) =:= 32,
       is_tuple(Ids), is_integer(Bits), Bits > 0, Bits rem 64 =:= 0 ->
    try ets:info(T, owner) =:= Owner andalso tuple_size(Ids) =< Bits andalso
        ets:lookup(T, '$efz_bitmap_schema') =:= [{'$efz_bitmap_schema', F}]
    catch error:badarg -> false end;
valid_schema(_) -> false.

valid_schema(Schema, Builds) ->
    valid_schema(Schema) andalso maps:get(builds, Schema) =:= Builds.

release(#{table := T, owner := Owner}) when Owner =:= self() ->
    ets:delete(T), ok;
release(_) -> error({efz_infrastructure, invalid_bitmap_schema_owner}).

open(Schema = #{capacity := Bits}) ->
    case valid_schema(Schema) of
        true ->
            Words = atomics:new(Bits div 64, [{signed, false}]),
            Active = atomics:new(1, [{signed, false}]),
            atomics:put(Active, 1, 1),
            {efz_context, 1, make_ref(), {bitmap, Schema, Words, Active}, self()};
        false -> error({efz_infrastructure, invalid_bitmap_schema})
    end.

%% The worker owns this reusable allocation. A guardian may arm it only after
%% the previous guardian has exited with confirmed cleanup. An unconfirmed map
%% is retired with its worker; Active=0 alone is not a quiescence proof.
allocate(Schema = #{capacity := Bits}) ->
    case valid_schema(Schema) of
        true -> {efz_bitmap_map, fingerprint(Schema),
                 atomics:new(Bits div 64, [{signed, false}]),
                 atomics:new(2, [{signed, false}])};
        false -> error({efz_infrastructure, invalid_bitmap_schema})
    end.

open(Schema = #{capacity := Bits, fingerprint := F},
     {efz_bitmap_map, F, Words, Active}) ->
    case valid_schema(Schema) of
        true ->
            case atomics:compare_exchange(Active, 1, 0, 2) of
                ok ->
                    clear_words(Words, Bits div 64, 1),
                    _ = atomics:add_get(Active, 2, 1),
                    atomics:put(Active, 1, 1),
                    {efz_context, 1, make_ref(), {bitmap, Schema, Words, Active}, self()};
                _ -> error({efz_infrastructure, bitmap_map_not_sealed})
            end;
        false -> error({efz_infrastructure, invalid_bitmap_schema})
    end;
open(_, _) -> error({efz_infrastructure, incompatible_coverage_schema}).

clear_words(_, Count, I) when I > Count -> ok;
clear_words(Words, Count, I) ->
    atomics:put(Words, I, 0), clear_words(Words, Count, I + 1).

seal({efz_context, 1, _, {bitmap, #{fingerprint := F, capacity := Bits}, Words, Active}, Owner})
  when Owner =:= self() ->
    1 = atomics:get(Active, 1),
    atomics:put(Active, 1, 0),
    {efz_bitmap_sealed, 1, F, Bits, Words, Active, atomics:get(Active, 2)};
seal(_) -> error({efz_infrastructure, invalid_coverage_context}).

valid_sealed({efz_bitmap_sealed, 1, F, Bits, _, Active, Generation}) ->
    is_binary(F) andalso byte_size(F) =:= 32 andalso
    is_integer(Bits) andalso Bits > 0 andalso Bits rem 64 =:= 0 andalso
    atomics:get(Active, 1) =:= 0 andalso atomics:get(Active, 2) =:= Generation.

has_new({efz_bitmap_snapshot, 1, F, Global},
        Sealed = {efz_bitmap_sealed, 1, F, Bits, Words, _, _})
  when is_binary(Global), byte_size(Global) =:= Bits div 8 ->
    case valid_sealed(Sealed) of
        true -> {ok, has_new_words(Global, Words, 1)};
        false -> {error, unsealed_coverage}
    end;
has_new(_, _) -> {error, incompatible_coverage_schema}.

has_new_words(<<>>, _, _) -> false;
has_new_words(<<G:64/little-unsigned, Rest/binary>>, Words, I) ->
    case atomics:get(Words, I) band bnot G of
        0 -> has_new_words(Rest, Words, I + 1);
        _ -> true
    end.

unseen_sealed({efz_bitmap_snapshot, 1, F, Global},
              Sealed = {efz_bitmap_sealed, 1, F, Bits, Words, _, _})
  when is_binary(Global), byte_size(Global) =:= Bits div 8 ->
    case valid_sealed(Sealed) of
        true -> {ok, {efz_bitmap_snapshot, 1, F,
                       sealed_wordwise(Global, Words, difference, 1, [])}};
        false -> {error, unsealed_coverage}
    end;
unseen_sealed(_, _) -> {error, incompatible_coverage_schema}.

merge_sealed({efz_bitmap_snapshot, 1, F, Global},
             Sealed = {efz_bitmap_sealed, 1, F, Bits, Words, _, _})
  when is_binary(Global), byte_size(Global) =:= Bits div 8 ->
    case valid_sealed(Sealed) of
        true -> {ok, {efz_bitmap_snapshot, 1, F,
                       sealed_wordwise(Global, Words, union, 1, [])}};
        false -> {error, unsealed_coverage}
    end;
merge_sealed(_, _) -> {error, incompatible_coverage_schema}.

sealed_wordwise(<<>>, _, _, _, Acc) -> iolist_to_binary(lists:reverse(Acc));
sealed_wordwise(<<G:64/little-unsigned, Rest/binary>>, Words, Mode, I, Acc) ->
    L = atomics:get(Words, I),
    W = case Mode of difference -> L band bnot G; union -> L bor G end,
    sealed_wordwise(Rest, Words, Mode, I + 1, [<<W:64/little-unsigned>> | Acc]).

count_sealed(Sealed = {efz_bitmap_sealed, 1, _, Bits, Words, _, _}) ->
    case valid_sealed(Sealed) of
        true -> {ok, count_words(Words, Bits div 64, 1, 0)};
        false -> {error, unsealed_coverage}
    end;
count_sealed(_) -> {error, invalid_coverage_context}.

count_words(_, Count, I, Acc) when I > Count -> Acc;
count_words(Words, Count, I, Acc) ->
    count_words(Words, Count, I + 1, Acc + popcount(atomics:get(Words, I), 0)).
popcount(0, Acc) -> Acc;
popcount(N, Acc) -> popcount(N band (N - 1), Acc + 1).

diagnostic_snapshot(Sealed = {efz_bitmap_sealed, 1, F, Bits, Words, _, _}) ->
    case valid_sealed(Sealed) of
        true -> {ok, {efz_bitmap_snapshot, 1, F,
                      iolist_to_binary([<<(atomics:get(Words, I)):64/little-unsigned>> ||
                                        I <- lists:seq(1, Bits div 64)])}};
        false -> {error, unsealed_coverage}
    end;
diagnostic_snapshot(_) -> {error, invalid_coverage_context}.

attach({efz_context, 1, Ref, {bitmap, Schema, _, Active}, Owner} = Context)
  when is_reference(Ref), is_pid(Owner) ->
    case is_process_alive(Owner) andalso valid_schema(Schema) andalso
         atomics:get(Active, 1) =:= 1 of
        true -> put('$efz_execution_context', Context), ok;
        false -> error({efz_infrastructure, invalid_coverage_context})
    end;
attach(_) -> error({efz_infrastructure, invalid_coverage_context}).

hit(Id, {efz_context, 1, Ref, {bitmap, #{table := T, capacity := Bits}, Words, Active}, Owner}) ->
    try
        1 = atomics:get(Active, 1),
        case ets:lookup(T, Id) of
            [{Id, Slot}] when is_integer(Slot), Slot >= 0, Slot < Bits ->
                Word = Slot div 64 + 1,
                Mask = 1 bsl (Slot rem 64),
                set_bit(Words, Active, Word, Mask, Ref, Id, Owner);
            _ -> fail(Ref, Owner, {unexpected_probe_or_build, Id})
        end
    catch
        error:{badmatch, _} -> fail(Ref, Owner, late_coverage_hit);
        error:badarg -> fail(Ref, Owner, invalid_coverage_table)
    end;
hit(_, _) -> error({efz_infrastructure, invalid_coverage_context}).

set_bit(Words, Active, Word, Mask, Ref, Id, Owner) ->
    Old = atomics:get(Words, Word),
    case Old band Mask of
        Mask -> ok;
        0 ->
            %% Recheck before a first write. Guardian quiescence, not this
            %% check, closes the remaining check-to-CAS race at sealing.
            1 = atomics:get(Active, 1),
            case cas_word(Words, Word, Mask, Old) of
                first -> Owner ! {efz_cov_observed, Ref, Id}, ok;
                already -> ok
            end
    end.

%% The four-argument form permits a deterministic stale-read test: two writers
%% can start from the same Old and prove the retry preserves both masks.
cas_word(Words, Word, Mask, Old) ->
    case Old band Mask of
        Mask -> already;
        0 -> case atomics:compare_exchange(Words, Word, Old, Old bor Mask) of
            ok -> first;
            Current -> cas_word(Words, Word, Mask, Current)
        end
    end.

-spec fail(reference(), pid(), term()) -> no_return().
fail(Ref, Owner, Why) ->
    Owner ! {efz_cov_failure, Ref, Why},
    error({efz_infrastructure, Why}).

snapshot(Context) ->
    case snapshot_bits(Context) of
        {ok, Bits} -> decode(schema(Context), Bits);
        Error -> Error
    end.

snapshot_bits({efz_context, 1, _, {bitmap, #{capacity := Bits,
                    fingerprint := F}, Words, Active}, Owner}) when Owner =:= self() ->
    try
        1 = atomics:get(Active, 1),
        Bytes = iolist_to_binary([<<(atomics:get(Words, I)):64/little-unsigned>> ||
                                 I <- lists:seq(1, Bits div 64)]),
        {ok, {efz_bitmap_snapshot, 1, F, Bytes}}
    catch error:_ -> {error, invalid_coverage_table} end;
snapshot_bits(_) -> {error, invalid_coverage_context}.

schema({efz_context, 1, _, {bitmap, Schema, _, _}, _}) -> Schema.

close({efz_context, 1, _, {bitmap, _, _, Active}, Owner}) when Owner =:= self() ->
    atomics:put(Active, 1, 0), ok;
close(_) -> error({efz_infrastructure, invalid_coverage_context}).

%% Legacy/low-level reset creates a fresh map. Campaign reuse uses open/2 only
%% after the guardian's confirmed cleanup and completed feedback.
reset({efz_context, 1, _, {bitmap, Schema, _, Active}, Owner}) when Owner =:= self() ->
    case atomics:get(Active, 1) of
        0 -> open(Schema);
        _ -> error({efz_infrastructure, bitmap_reset_requires_close})
    end.

%% Only a caller that has joined every writer may use this benchmark primitive.
clear_quiescent({efz_context, 1, _, {bitmap, #{capacity := Bits}, Words, Active},
                 Owner}) when Owner =:= self() ->
    case atomics:get(Active, 1) of
        0 -> lists:foreach(fun(I) -> atomics:put(Words, I, 0) end,
                           lists:seq(1, Bits div 64)), ok;
        _ -> error({efz_infrastructure, bitmap_clear_requires_close})
    end.

new_global(#{capacity := Bits, fingerprint := F} = Schema) ->
    case valid_schema(Schema) of
        true -> {efz_bitmap_snapshot, 1, F, binary:copy(<<0>>, Bits div 8)};
        false -> error({efz_infrastructure, invalid_bitmap_schema})
    end.

unseen_bits({efz_bitmap_snapshot, 1, F, Global},
            {efz_bitmap_snapshot, 1, F, Local})
  when is_binary(F), byte_size(F) =:= 32, is_binary(Global), is_binary(Local),
       byte_size(Global) =:= byte_size(Local), byte_size(Global) > 0,
       byte_size(Global) rem 8 =:= 0 ->
    {ok, {efz_bitmap_snapshot, 1, F, wordwise(Local, Global, difference, [])}};
unseen_bits(_, _) -> {error, incompatible_coverage_schema}.

merge_bits({efz_bitmap_snapshot, 1, F, Global},
           {efz_bitmap_snapshot, 1, F, Local})
  when is_binary(F), byte_size(F) =:= 32, is_binary(Global), is_binary(Local),
       byte_size(Global) =:= byte_size(Local), byte_size(Global) > 0,
       byte_size(Global) rem 8 =:= 0 ->
    {ok, {efz_bitmap_snapshot, 1, F, wordwise(Local, Global, union, [])}};
merge_bits(_, _) -> {error, incompatible_coverage_schema}.

wordwise(<<>>, <<>>, _, Acc) -> iolist_to_binary(lists:reverse(Acc));
wordwise(<<L:64/little-unsigned, Ls/binary>>,
         <<G:64/little-unsigned, Gs/binary>>, Mode, Acc) ->
    W = case Mode of difference -> L band bnot G; union -> L bor G end,
    wordwise(Ls, Gs, Mode, [<<W:64/little-unsigned>> | Acc]).

decode(#{fingerprint := F, capacity := Bits, ids := Ids} = Schema,
       {efz_bitmap_snapshot, 1, F, Bytes}) when byte_size(Bytes) =:= Bits div 8 ->
    case valid_schema(Schema) of
        true -> case valid_padding(Bytes, tuple_size(Ids)) of
            true -> {ok, lists:sort([element(I + 1, Ids) || I <- lists:seq(0, tuple_size(Ids)-1),
                       (binary:at(Bytes, I div 8) band (1 bsl (I rem 8))) =/= 0])};
            false -> {error, unexpected_bitmap_slot}
        end;
        false -> {error, invalid_bitmap_schema}
    end;
decode(_, _) -> {error, incompatible_coverage_schema}.

valid_padding(Bytes, Count) ->
    First = Count div 8,
    case Count rem 8 of
        0 -> zero_tail(Bytes, First);
        N ->
            (binary:at(Bytes, First) band (255 bxor ((1 bsl N)-1))) =:= 0
            andalso zero_tail(Bytes, First + 1)
    end.
zero_tail(Bytes, First) ->
    Tail = binary:part(Bytes, First, byte_size(Bytes)-First),
    Tail =:= binary:copy(<<0>>, byte_size(Tail)).

global_snapshot(Schema, Snapshot) -> decode(Schema, Snapshot).
fingerprint(#{fingerprint := F}) -> F.
memory({efz_context, 1, _, {bitmap, #{table := T, ids := Ids}, Words, Active}, _}) ->
    #{words => maps:get(memory, atomics:info(Words)),
      active => maps:get(memory, atomics:info(Active)),
      mapping_words => ets:info(T, memory),
      reverse_bytes => erlang:external_size(Ids)}.
