-module(efz_spec_fixture).
-export([combine/3, bounded/1, shadow/1, nested/1, primitives/1, zero/0,
    union_alias/1, overload/1, mixed/1, required/1, fields/1, remote/1,
    recursive/1, opaque_arg/1, unconstrained/1, atom_arg/1, runtime_arg/1,
    no_spec/1, stride/1, wide/1, expression/1, too_deep/1, qualified/1, labeled/1]).
-export_type([handle/0]).

-type mode() :: read | write.
-type wrapper(T) :: {tag, T}.
-type tree() :: leaf | {node, tree()}.
-opaque handle() :: integer().
-type deep1() :: {integer()}.
-type deep2() :: {deep1()}.
-type deep3() :: {deep2()}.
-type deep4() :: {deep3()}.
-type deep5() :: {deep4()}.
-type deep6() :: {deep5()}.
-type deep7() :: {deep6()}.
-type deep8() :: {deep7()}.

-spec combine([wrapper(0..3)], mode(), #{mode() => binary()}) -> term().
combine(Items, Mode, Values) -> {Items, Mode, Values}.

-spec bounded(T) -> T when T :: U, U :: 1..4.
bounded(Value) -> Value.

-spec shadow(T) -> T when T :: wrapper(integer()).
shadow(Value) -> Value.

-spec nested(wrapper(wrapper(binary()))) -> term().
nested(Value) -> Value.

-spec primitives({integer(), float(), boolean(), byte(), arity(), char(),
    pos_integer(), neg_integer(), non_neg_integer(), nonempty_binary(),
    string(), [], #{}, <<_:16>>}) -> term().
primitives(Value) -> Value.

-spec zero() -> pid().
zero() -> self().

-spec union_alias(mode() | other) -> atom().
union_alias(Value) -> Value.

-spec overload(integer()) -> integer(); (binary()) -> binary().
overload(Value) -> Value.

-spec mixed(integer() | binary()) -> term().
mixed(Value) -> Value.

-spec required(#{name := binary()}) -> term().
required(Value) -> Value.

-spec fields(#{name => binary(), age => integer()}) -> term().
fields(Value) -> Value.

-spec remote(file:filename()) -> term().
remote(Value) -> Value.

-spec recursive(tree()) -> term().
recursive(Value) -> Value.

-spec opaque_arg(handle()) -> term().
opaque_arg(Value) -> Value.

-spec unconstrained(T) -> T.
unconstrained(Value) -> Value.

-spec atom_arg(atom()) -> term().
atom_arg(Value) -> Value.

-spec runtime_arg(pid()) -> pid().
runtime_arg(Value) -> Value.

no_spec(Value) -> Value.

-spec stride(<<_:_*16>>) -> binary().
stride(Value) -> Value.

-spec wide(0..18446744073709551616) -> integer().
wide(Value) -> Value.

-spec expression(0..((1 bsl 8) - 1)) -> integer().
expression(Value) -> Value.

-spec too_deep(deep8()) -> term().
too_deep(Value) -> Value.

-spec efz_spec_fixture:qualified(nonempty_list(<<_:8, _:_*8>>)) -> term().
qualified(Value) -> Value.

-spec labeled(Count :: -3..3) -> integer().
labeled(Count) -> Count.
