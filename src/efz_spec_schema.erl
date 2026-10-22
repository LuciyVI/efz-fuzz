%% Cold, bounded translation of trusted BEAM specs to term/API options.
%% Does not load the target or infer correctness properties from return types.
-module(efz_spec_schema).
-export([inspect/1, from_beam/3, format_diagnostic/1]).

inspect(Path) ->
    case read_beam(Path) of
        {ok, Module, Forms, Exports, Hash} ->
            Types = maps:from_list([{{Name, length(Params)}, {Kind, Body, Params}}
                || {attribute, _, Kind, {Name, Body, Params}} <- Forms,
                   Kind =:= type orelse Kind =:= opaque]),
            Specs = maps:from_list([{spec_key(FA, Module), {Anno, Clauses}}
                || {attribute, Anno, spec, {FA, Clauses}} <- Forms]),
            Context = #{module => Module, types => Types, specs => Specs,
                vars => #{}, stack => [], path => [], steps => 0},
            Entries = [entry(F, A, Context) || {F, A} <- lists:sort(Exports),
                {F, A} =/= {module_info, 0}, {F, A} =/= {module_info, 1}],
            {ok, #{schema_version => 1, module => Module,
                beam => filename:absname(Path), beam_sha256 => Hash,
                limits => efz_term_codec:limits(#{}), entries => Entries,
                manual => [invariants, expected_exceptions, stateful_lifecycle, oracle]}};
        {error, _} = Error -> Error
    end.

spec_key({M, F, A}, M) -> {F, A};
spec_key(FA, _) -> FA.

from_beam(Path, Function, Arity) ->
    case inspect(Path) of
        {ok, #{entries := Entries, module := Module} = API} ->
            case [E || #{entrypoint := MFA} = E <- Entries,
                       MFA =:= {Module, Function, Arity}] of
                [#{status := supported} = Entry] ->
                    {ok, Entry#{source => maps:without([entries], API)}};
                [#{diagnostics := [Diagnostic | _]}] -> {error, Diagnostic};
                [] -> {error, diagnostic(not_exported,
                    "Select an exported function and arity.", #{}, undefined)}
            end;
        {error, _} = Error -> Error
    end.

%% Only the standard Erlang debug backend is accepted. Reading abstract_code
%% directly can invoke the backend named in the BEAM's debug_info chunk.
read_beam(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> read_beam_bytes(Bytes);
        {error, Why} -> beam_error(Why)
    end.
read_beam_bytes(Bytes) ->
    case beam_lib:chunks(Bytes, [debug_info, exports]) of
        {ok, {Module, Chunks}} ->
            case proplists:get_value(debug_info, Chunks) of
                {debug_info_v1, erl_abstract_code, {Forms, _}} when is_list(Forms) ->
                    {ok, Module, Forms, proplists:get_value(exports, Chunks), crypto:hash(sha256, Bytes)};
                {debug_info_v1, erl_abstract_code, {none, _}} -> missing_debug_info();
                {debug_info_v1, _, _} ->
                    {error, diagnostic(unsupported_debug_backend,
                        "Recompile with the standard Erlang +debug_info backend.", #{}, undefined)};
                _ -> missing_debug_info()
            end;
        {error, beam_lib, {missing_chunk, _, _}} -> missing_debug_info();
        Failure -> beam_error(Failure)
    end.

missing_debug_info() ->
    {error, diagnostic(missing_abstract_code,
        "BEAM has no Erlang abstract code; recompile with +debug_info.", #{}, undefined)}.
beam_error(Why) ->
    {error, (diagnostic(invalid_beam, "Cannot read BEAM metadata.", #{}, undefined))#{detail => Why}}.

entry(F, A, #{module := M, specs := Specs} = C) ->
    Base = #{entrypoint => {M, F, A}, spec => spec_text(F, A, Specs)},
    try
        {Anno, Clauses} = case maps:find({F, A}, Specs) of
            {ok, Value} -> Value;
            error -> reject(missing_spec, "Export has no -spec; supply manual argument schemas.", C, undefined)
        end,
        Clause = case Clauses of
            [One] -> One;
            _ -> reject(overloaded_spec,
                "Overloaded -spec has correlated alternatives; select a contract manually.", C, Anno)
        end,
        {Args, C1} = arguments(Clause, C),
        {Schemas, Notes} = many(Args, C1, arg, 1),
        Options = #{entrypoint => {M, F, A}, arguments => Schemas},
        case length(Schemas) =:= A andalso efz_term_codec:validate_specs(Schemas, #{}) =:= ok of
            true -> ok;
            false -> reject(schema_limit,
                "Inferred schema exceeds the default codec envelope; use manual options.", C, Anno)
        end,
        case lists:any(fun(I) -> case efz_term_api_adapter:seed(I, Options, #{}) of
                {ok, _} -> true; _ -> false end end, lists:seq(0, 31)) of
            true -> ok;
            false -> reject(seed_limit,
                "None of the first 32 deterministic seed indices fits the codec/generator bounds; "
                "use manual options.", C, Anno)
        end,
        Bounded = (diagnostic(bounded_domain,
            "Generation uses codec bounds: integers +/-1000000, finite floats +/-1000000, "
            "collections 32, bytes 4096, depth 8, nodes 128. Explicit integer ranges must fit int64. "
            "This is a bounded subset of the signature, not a correctness oracle.", C, Anno))#{severity => info},
        Base#{status => supported, options => Options, diagnostics => [Bounded | Notes]}
    catch
        throw:{spec_schema, Diagnostic} -> Base#{status => unsupported, diagnostics => [Diagnostic]}
    end.

arguments({type, _, 'fun', [{type, _, product, Args}, _Return]}, C) -> {Args, C};
arguments({type, _, bounded_fun, [Fun, Constraints]}, C) ->
    Vars = lists:foldl(fun
        ({type, _, constraint, [{atom, _, is_subtype}, [{var, _, Name}, Type]]}, Acc) ->
            case maps:is_key(Name, Acc) of
                false -> Acc#{Name => {Type, constraint}};
                true -> reject(ambiguous_constraint,
                    "Multiple bounds for one variable need a manual intersection.", C, Type)
            end;
        (Other, _) -> reject(unsupported_constraint, "Unsupported -spec constraint.", C, Other)
    end, #{}, Constraints),
    arguments(Fun, C#{vars => Vars});
arguments(Other, C) -> reject(unsupported_spec, "Expected a fixed-arity function spec.", C, Other).

many([], _, _, _) -> {[], []};
many([T | Rest], C, Kind, Index) ->
    {S, Notes} = schema(T, child(C, {Kind, Index})),
    {Ss, More} = many(Rest, C, Kind, Index + 1),
    {[S | Ss], Notes ++ More}.

child(#{path := Path} = C, Step) -> C#{path => Path ++ [Step]}.
schema(T, #{steps := Steps} = C) when Steps < 64 ->
    {S, Notes} = translate(T, C#{steps => Steps + 1}),
    %% Check every expansion, rather than constructing an exponentially large
    %% alias tree and checking only the final root.
    case efz_term_codec:validate_specs([S], #{}) of
        ok -> {S, Notes};
        _ -> reject(schema_limit,
            "Inferred schema exceeds the default codec envelope; use manual options.", C, T)
    end;
schema(T, C) -> reject(expansion_limit, "Type expansion exceeds 64 levels.", C, T).

translate({ann_type, _, [_Name, Type]}, C) -> schema(Type, C);
translate({var, _, Name} = T, #{vars := Vars, stack := Stack} = C) ->
    Key = {variable, Name, Vars},
    case {lists:member(Key, Stack), maps:find(Name, Vars)} of
        {false, {ok, {resolved, S, Notes}}} -> {S, Notes};
        {false, {ok, {Type, constraint}}} ->
            schema(Type, C#{stack => [Key | Stack]});
        {true, _} -> reject(recursive_type, "Recursive type variable needs a manual schema.", C, T);
        {_, error} -> reject(unbound_variable,
            "Type variable has no finite bound; supply an explicit argument schema.", C, T)
    end;
translate({user_type, _, Name, Args} = T, #{types := Types, stack := Stack} = C) ->
    Key = {alias, Name, length(Args)},
    case {lists:member(Key, Stack), maps:find({Name, length(Args)}, Types)} of
        {true, _} -> reject(recursive_type, "Recursive -type needs a bounded manual model.", C, T);
        {false, {ok, {opaque, _, _}}} -> reject(opaque_type,
            "Opaque values require their public constructors and a custom harness.", C, T);
        {false, {ok, {type, Body, Params}}} ->
            %% Resolve actual parameters in their caller scope before entering
            %% the alias. This allows box(box(integer())) without mistaking it
            %% for a recursive declaration or capturing same-named variables.
            Resolved = [begin {S, Ns} = schema(Arg, C), {resolved, S, Ns} end || Arg <- Args],
            Vars = maps:from_list([{Name0, Arg}
                || {{var, _, Name0}, Arg} <- lists:zip(Params, Resolved)]),
            schema(Body, C#{vars => Vars, stack => [Key | Stack]});
        {_, error} -> reject(unknown_type, "Local -type definition was not found.", C, T)
    end;
translate({remote_type, _, _} = T, C) -> reject(remote_type,
    "Remote type definitions are not read implicitly; supply a reviewed manual schema.", C, T);
translate({atom, _, Atom}, _) -> {#{kind => atom, values => [Atom]}, []};
translate({integer, _, N} = T, C) -> integer_range(N, N, C, T);
translate({char, _, N} = T, C) -> integer_range(N, N, C, T);
translate({op, _, _, _} = T, C) -> N = integer_value(T, C), integer_range(N, N, C, T);
translate({op, _, _, _, _} = T, C) -> N = integer_value(T, C), integer_range(N, N, C, T);
translate({type, _, range, [Low, High]} = T, C) ->
    integer_range(integer_value(Low, C), integer_value(High, C), C, T);
translate({type, _, integer, []}, _) -> {#{kind => integer}, []};
translate({type, _, non_neg_integer, []}, _) -> {#{kind => integer, min => 0}, []};
translate({type, _, pos_integer, []}, _) -> {#{kind => integer, min => 1}, []};
translate({type, _, neg_integer, []}, _) -> {#{kind => integer, max => -1}, []};
translate({type, _, byte, []}, _) -> {#{kind => integer, min => 0, max => 255}, []};
translate({type, _, arity, []}, C) -> translate({type, 0, byte, []}, C);
translate({type, _, char, []}, _) -> {#{kind => integer, min => 0, max => 16#10ffff}, []};
translate({type, _, float, []}, _) -> {#{kind => float}, []};
translate({type, _, boolean, []}, _) -> {#{kind => boolean}, []};
translate({type, _, binary, []} = T, C) -> binary_schema(0, 32, C, T);
translate({type, _, nonempty_binary, []} = T, C) -> binary_schema(1, 32, C, T);
translate({type, _, binary, [Base, Unit]} = T, C) ->
    B = integer_value(Base, C), U = integer_value(Unit, C),
    case {B, U} of
        {N, 0} when N >= 0, N rem 8 =:= 0, N div 8 =< 32 ->
            binary_schema(N div 8, N div 8, C, T);
        {N, 8} when N >= 0, N rem 8 =:= 0, N div 8 =< 32 ->
            binary_schema(N div 8, 32, C, T);
        _ -> reject(binary_size_constraint,
            "Bit alignment or size stride cannot be represented by a bounded byte schema.", C, T)
    end;
translate({type, _, nil, []}, _) ->
    {#{kind => list, min_length => 0, max_length => 0, item => #{kind => integer}}, []};
translate({type, _, string, []}, C) -> string_schema(0, C);
translate({type, _, nonempty_string, []}, C) -> string_schema(1, C);
translate({type, _, Kind, [Item]}, C) when Kind =:= list; Kind =:= nonempty_list ->
    {S, Notes} = schema(Item, child(C, item)),
    Min = case Kind of list -> 0; nonempty_list -> 1 end,
    {#{kind => list, item => S, min_length => Min, max_length => 32}, Notes};
translate({type, _, tuple, Items}, C) when is_list(Items) ->
    {Ss, Notes} = many(Items, C, tuple, 1), {#{kind => tuple, items => Ss}, Notes};
translate({type, _, map, []}, _) ->
    {#{kind => map, min_length => 0, max_length => 0,
       key => #{kind => integer}, value => #{kind => integer}}, []};
translate({type, _, map, [{type, _, map_field_assoc, [Key, Value]}]}, C) ->
    {K, KN} = schema(Key, child(C, key)), {V, VN} = schema(Value, child(C, value)),
    {#{kind => map, key => K, value => V, min_length => 0, max_length => 32}, KN ++ VN};
translate({type, _, map, Fields} = T, C) when is_list(Fields) ->
    reject(map_constraints,
        "Required or multiple map fields cannot be preserved by the homogeneous map schema.", C, T);
translate({type, _, union, Types} = T, C) ->
    {Schemas, Notes} = many(Types, C, alternative, 1),
    Values = lists:flatmap(fun
        (#{kind := atom, values := Vs}) -> Vs;
        (#{kind := boolean}) -> [false, true];
        (_) -> reject(ambiguous_union,
            "Only finite atom unions are representable; select a manual argument contract.", C, T)
    end, Schemas),
    {#{kind => atom, values => lists:usort(Values)}, Notes};
translate({type, _, Kind, _} = T, C) when Kind =:= atom; Kind =:= term;
        Kind =:= any; Kind =:= list; Kind =:= map; Kind =:= tuple ->
    reject(ambiguous_type,
        "Type lacks a finite atom set or element/field schema; supply manual constraints.", C, T);
translate(T, C) -> reject(unsupported_type,
    "Type is not representable by the portable term codec; use a manual schema or lifecycle harness.", C, T).

integer_range(Min, Max, _, _) when is_integer(Min), is_integer(Max), Min =< Max,
        Min >= -9223372036854775808, Max =< 9223372036854775807 ->
    {#{kind => integer, min => Min, max => Max}, []};
integer_range(_, _, C, T) -> reject(integer_range,
    "Explicit integer range is empty or exceeds the signed int64 codec envelope.", C, T).

%% Constant type expressions contain integers and operators only. Never eval
%% arbitrary source forms, calls or target code while inspecting metadata.
integer_value({integer, _, N}, _) -> N;
integer_value({char, _, N}, _) -> N;
integer_value({op, _, '-', T}, C) -> -integer_value(T, C);
integer_value({op, _, '+', T}, C) -> integer_value(T, C);
integer_value(T, C) -> reject(unsupported_integer_expression,
    "Use literal integer bounds (unary +/- supported) or a manual schema.", C, T).

binary_schema(Min, Max, C, T) ->
    Note = (diagnostic(binary_semantics_unknown,
        "binary() is treated as raw bytes. UTF-8, JSON, protocol grammar and cross-field "
        "constraints cannot be inferred from -spec; add a domain adapter when required.", C, T))#{severity => warning},
    {#{kind => binary, min_length => Min, max_length => Max}, [Note]}.
string_schema(Min, C) ->
    %% Erlang char() includes surrogate codepoints; codec charlist excludes them.
    %% A list of bounded integers preserves the declared string domain instead.
    translate({type, 0, case Min of 0 -> list; 1 -> nonempty_list end,
        [{type, 0, char, []}]}, C).

reject(Code, Message, C, T) -> throw({spec_schema, diagnostic(Code, Message, C, T)}).
diagnostic(Code, Message, C, T) ->
    #{severity => error, code => Code, message => list_to_binary(Message),
      path => maps:get(path, C, []), location => location(T), type => type_text(T)}.
location({Line, Column}) when is_integer(Line), is_integer(Column) -> {Line, Column};
location(T) when is_tuple(T), tuple_size(T) >= 2 -> location(element(2, T));
location(undefined) -> undefined;
location(Anno) -> try erl_anno:location(Anno) catch _:_ -> undefined end.
type_text(undefined) -> <<>>;
type_text({Line, Column}) when is_integer(Line), is_integer(Column) -> <<>>;
type_text(T) when is_tuple(T) ->
    try iolist_to_binary(erl_pp:attribute({attribute, 0, type, {inferred, T, []}}))
    catch _:_ -> iolist_to_binary(io_lib:format("~tp", [T])) end;
type_text(_) -> <<>>.

spec_text(F, A, Specs) ->
    case maps:find({F, A}, Specs) of
        {ok, {Anno, Clauses}} ->
            iolist_to_binary(erl_pp:attribute({attribute, Anno, spec, {{F, A}, Clauses}}));
        error -> <<>>
    end.

format_diagnostic(#{code := Code, message := Message, path := Path,
                    location := Location, type := Type}) ->
    io_lib:format("~p at ~tp (~tp): ~ts~s", [Code, Path, Location, Message,
        case Type of <<>> -> []; _ -> io_lib:format(" Type: ~ts", [Type]) end]).
