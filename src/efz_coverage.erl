%% Storage boundary for one execution and the campaign's exact probe set.
%% The execution context is deliberately kept in its historical wire shape.
-module(efz_coverage).
-export([open/2, open/3, attach/1, hit/2, snapshot/1, snapshot_bits/1,
         counts/1, count_features/2, close/1, prepare_schema/2, release_schema/1,
         check_capacity/2, valid_schema/2, new_global/1, unseen_bits/2,
         merge_bits/2, decode_new/2, allocate_execution/1, open/4,
         seal/1, has_new/2, unseen_sealed/2, commit_sealed/2,
         sealed_count/1, diagnostic_snapshot/1,
         new_global/0, unseen/2, merge/2, global_snapshot/1,
         modules_seen/2, missing_modules/2, observed_modules/1,
         prepare_native/1, valid_native/2, native_collect/1,
         native_empty/1, native_has_new/2, native_unseen/2,
         native_merge/2, native_decode/2, native_count/1,
         native_modules/2]).

open(Backend, Feedback) when Backend =:= ets; Backend =:= ets_member ->
    efz_cov_ets:open(Backend, Feedback);
open(none,presence) -> {efz_context,1,make_ref(),none,self()};
open(_, _) -> error({efz_infrastructure, unsupported_coverage_backend}).

open(bitmap, presence, Schema) -> efz_cov_bitmap:open(Schema);
open(otp_native_public, presence, Schema) -> efz_cov_native_public:open(Schema);
open(Backend, Feedback, _) -> open(Backend, Feedback).
open(bitmap, presence, Schema, Map) -> efz_cov_bitmap:open(Schema, Map);
open(Backend, Feedback, Schema, _) -> open(Backend, Feedback, Schema).

attach({efz_context, 1, _, {bitmap, _, _, _}, _} = Context) -> efz_cov_bitmap:attach(Context);
attach({efz_context,1,Ref,none,Owner}=Context) when is_reference(Ref), is_pid(Owner) ->
    put('$efz_execution_context',Context),ok;
attach({efz_context, 1, _, {otp_native_public,_}, _} = Context) -> efz_cov_native_public:attach(Context);
attach(Context) -> efz_cov_ets:attach(Context).
hit(Id, {efz_context, 1, _, {bitmap, _, _, _}, _} = Context) -> efz_cov_bitmap:hit(Id, Context);
hit(_, {efz_context,1,_,none,_}) -> error({efz_infrastructure,hit_in_no_coverage_mode});
hit(Id, Context) -> efz_cov_ets:hit(Id, Context).
snapshot({efz_context, 1, _, {bitmap, _, _, _}, _} = Context) -> efz_cov_bitmap:snapshot(Context);
snapshot({efz_context,1,_,none,_}) -> {ok,[]};
snapshot({efz_context, 1, _, {otp_native_public,Schema}, _}) -> efz_cov_native_public:collect(Schema);
snapshot(Context) -> efz_cov_ets:snapshot(Context).
snapshot_bits({efz_context, 1, _, {bitmap, _, _, _}, _} = Context) -> efz_cov_bitmap:snapshot_bits(Context);
snapshot_bits(_) -> none.
counts(Context) -> efz_cov_ets:counts(Context).
count_features(Hits, Counts) -> efz_cov_ets:count_features(Hits, Counts).
close({efz_context, 1, _, {bitmap, _, _, _}, _} = Context) -> efz_cov_bitmap:close(Context);
close({efz_context,1,_,none,_}) -> ok;
close({efz_context, 1, _, {otp_native_public,_}, _} = Context) -> efz_cov_native_public:close(Context);
close(Context) -> efz_cov_ets:close(Context).

prepare_schema(Manifests, Bits) -> efz_cov_bitmap:prepare(Manifests, Bits).
release_schema(Schema) -> efz_cov_bitmap:release(Schema).
check_capacity(Manifests, Bits) -> efz_cov_bitmap:check_capacity(Manifests, Bits).
valid_schema(Schema, Builds) -> efz_cov_bitmap:valid_schema(Schema, Builds).
new_global(Schema) -> efz_cov_bitmap:new_global(Schema).
prepare_native(Manifests) -> efz_cov_native_public:prepare(Manifests).
valid_native(#{kind:=otp_native_line}=Schema,Builds) ->
    efz_cov_native_public:valid(Schema,Builds);
valid_native(_,_) -> false.
native_collect(Schema) -> efz_cov_native_public:collect(Schema).
native_empty(Schema) -> efz_cov_native_public:empty(Schema).
native_has_new(Global,Current) -> efz_cov_native_public:has_new(Global,Current).
native_unseen(Global,Current) -> efz_cov_native_public:unseen(Global,Current).
native_merge(Global,Current) -> efz_cov_native_public:merge(Global,Current).
native_decode(Schema,Bits) -> efz_cov_native_public:decode(Schema,Bits).
native_count(Bits) -> efz_cov_native_public:count(Bits).
native_modules(Schema,Bits) -> efz_cov_native_public:modules(Schema,Bits).
unseen_bits(Global, Local) -> efz_cov_bitmap:unseen_bits(Global, Local).
merge_bits(Global, Local) -> efz_cov_bitmap:merge_bits(Global, Local).
decode_new(Schema, Bits) -> efz_cov_bitmap:decode(Schema, Bits).
allocate_execution(Schema) -> efz_cov_bitmap:allocate(Schema).
seal(Context) -> efz_cov_bitmap:seal(Context).
has_new(Global, Sealed) -> efz_cov_bitmap:has_new(Global, Sealed).
unseen_sealed(Global, Sealed) -> efz_cov_bitmap:unseen_sealed(Global, Sealed).
commit_sealed(Global, Sealed) -> efz_cov_bitmap:merge_sealed(Global, Sealed).
sealed_count(Sealed) -> efz_cov_bitmap:count_sealed(Sealed).
diagnostic_snapshot(Sealed) -> efz_cov_bitmap:diagnostic_snapshot(Sealed).

new_global() -> efz_cov_ets:new_global().
unseen(Global, Local) -> efz_cov_ets:unseen(Global, Local).
merge(Global, Local) -> efz_cov_ets:merge(Global, Local).
global_snapshot({efz_bitmap_schema, Schema, Snapshot}) ->
    {ok, Hits} = efz_cov_bitmap:global_snapshot(Schema, Snapshot), Hits;
global_snapshot({efz_native_schema,Schema,Bits}) -> efz_cov_native_public:decode(Schema,Bits);
global_snapshot(Global) -> efz_cov_ets:global_snapshot(Global).

%% Campaign diagnostics use the same exact-set representation, hidden from the worker.
modules_seen(Seen, Hits) -> efz_cov_ets:modules_seen(Seen, Hits).
missing_modules(Seen, Manifests) -> efz_cov_ets:missing_modules(Seen, Manifests).
observed_modules(Seen) -> efz_cov_ets:global_snapshot(Seen).
