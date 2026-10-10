// Independent, finite ASCII XML-RPC methodCall subset. No xmerl/target calls.
pub type Value {
  Xint(Int)
  Xbool(Bool)
  Xstring(BitArray)
  Xarray(List(Value))
  Xstruct(List(Member))
}
pub type Member { Member(name: BitArray, value: Value) }
pub type Call { Call(method: BitArray, params: List(Value)) }
pub type Limits {
  Limits(bytes: Int, depth: Int, nodes: Int, collection: Int, string_bytes: Int)
}
pub type Rejection { Unsupported Limit }

@external(erlang, "erlang", "byte_size")
fn size(value: BitArray) -> Int
@external(erlang, "erlang", "integer_to_binary")
fn decimal(value: Int) -> BitArray

pub fn version() -> Int { 1 }
pub fn normalize(model: Call) -> Call { model }
fn reverse(xs: List(a), acc: List(a)) -> List(a) {
  case xs { [] -> acc [x, ..rest] -> reverse(rest, [x, ..acc]) }
}

// Only printable ASCII text and the five predefined XML entities. No DTD,
// namespace, arbitrary tags, CDATA, numeric entities or non-ASCII codepoints.
fn text(input: BitArray, out: BitArray, limit: Int) -> Result(#(BitArray, BitArray), Rejection) {
  text_n(input, out, 0, limit)
}
fn text_n(input: BitArray, out: BitArray, count: Int, limit: Int) -> Result(#(BitArray, BitArray), Rejection) {
  case input {
    <<60, _:bits>> -> Ok(#(out, input))
    _ if count >= limit -> Error(Limit)
    <<"&amp;":utf8, rest:bits>> -> text_n(rest, <<out:bits, 38>>, count + 1, limit)
    <<"&lt;":utf8, rest:bits>> -> text_n(rest, <<out:bits, 60>>, count + 1, limit)
    <<"&gt;":utf8, rest:bits>> -> text_n(rest, <<out:bits, 62>>, count + 1, limit)
    <<"&quot;":utf8, rest:bits>> -> text_n(rest, <<out:bits, 34>>, count + 1, limit)
    <<"&apos;":utf8, rest:bits>> -> text_n(rest, <<out:bits, 39>>, count + 1, limit)
    <<b, rest:bits>> if b >= 32 && b <= 126 && b != 38 ->
      text_n(rest, <<out:bits, b>>, count + 1, limit)
    _ -> Error(Unsupported)
  }
}
fn integer(input: BitArray) -> Result(Int, Rejection) {
  case input {
    <<45, rest:bits>> -> digits(rest, 0, 0, -1)
    _ -> digits(input, 0, 0, 1)
  }
}
fn digits(input: BitArray, number: Int, count: Int, sign: Int) -> Result(Int, Rejection) {
  case input {
    <<>> if count > 0 && number * sign >= -2_147_483_648
      && number * sign <= 2_147_483_647 -> Ok(number * sign)
    <<b, rest:bits>> if b >= 48 && b <= 57 && count < 10 ->
      digits(rest, number * 10 + b - 48, count + 1, sign)
    _ -> Error(Unsupported)
  }
}
fn value(input: BitArray, depth: Int, remaining: Int, limits: Limits)
  -> Result(#(Value, BitArray, Int), Rejection) {
  case depth > limits.depth || remaining <= 0 {
    True -> Error(Limit)
    False -> case input {
      <<"<value><int>":utf8, rest:bits>> -> case text(rest, <<>>, 11) {
        Ok(#(digits, <<"</int></value>":utf8, tail:bits>>)) -> case integer(digits) {
          Ok(n) -> Ok(#(Xint(n), tail, remaining - 1))
          Error(e) -> Error(e)
        }
        Error(e) -> Error(e)
        _ -> Error(Unsupported)
      }
      <<"<value><boolean>0</boolean></value>":utf8, rest:bits>> ->
        Ok(#(Xbool(False), rest, remaining - 1))
      <<"<value><boolean>1</boolean></value>":utf8, rest:bits>> ->
        Ok(#(Xbool(True), rest, remaining - 1))
      <<"<value><string>":utf8, rest:bits>> -> case text(rest, <<>>, limits.string_bytes) {
        Ok(#(s, <<"</string></value>":utf8, tail:bits>>)) ->
          Ok(#(Xstring(s), tail, remaining - 1))
        Error(e) -> Error(e)
        _ -> Error(Unsupported)
      }
      <<"<value><array><data>":utf8, rest:bits>> ->
        case values(rest, depth + 1, remaining - 1, 0, [], limits) {
          Ok(#(xs, <<"</data></array></value>":utf8, tail:bits>>, n)) ->
            Ok(#(Xarray(xs), tail, n))
          Error(e) -> Error(e)
          _ -> Error(Unsupported)
        }
      <<"<value><struct>":utf8, rest:bits>> ->
        case members(rest, depth + 1, remaining - 1, 0, [], limits) {
          Ok(#(xs, tail, n)) -> Ok(#(Xstruct(xs), tail, n))
          Error(e) -> Error(e)
        }
      _ -> Error(Unsupported)
    }
  }
}
fn values(input: BitArray, depth: Int, remaining: Int, count: Int,
  acc: List(Value), limits: Limits) -> Result(#(List(Value), BitArray, Int), Rejection) {
  case input {
    <<"</data>":utf8, _:bits>> -> Ok(#(reverse(acc, []), input, remaining))
    _ if count >= limits.collection -> Error(Limit)
    _ -> case value(input, depth, remaining, limits) {
      Ok(#(v, rest, n)) -> values(rest, depth, n, count + 1, [v, ..acc], limits)
      Error(e) -> Error(e)
    }
  }
}
fn members(input: BitArray, depth: Int, remaining: Int, count: Int,
  acc: List(Member), limits: Limits) -> Result(#(List(Member), BitArray, Int), Rejection) {
  case input {
    <<"</struct></value>":utf8, rest:bits>> -> Ok(#(reverse(acc, []), rest, remaining))
    _ if count >= limits.collection || remaining <= 0 -> Error(Limit)
    <<"<member><name>":utf8, rest:bits>> -> case text(rest, <<>>, limits.string_bytes) {
      Ok(#(name, <<"</name>":utf8, tail:bits>>)) if name != <<>> ->
        case value(tail, depth, remaining - 1, limits) {
          Ok(#(v, <<"</member>":utf8, next:bits>>, n)) ->
            members(next, depth, n, count + 1, [Member(name, v), ..acc], limits)
          Error(e) -> Error(e)
          _ -> Error(Unsupported)
        }
      Error(e) -> Error(e)
      _ -> Error(Unsupported)
    }
    _ -> Error(Unsupported)
  }
}
fn params(input: BitArray, remaining: Int, count: Int, acc: List(Value), limits: Limits)
  -> Result(#(List(Value), BitArray), Rejection) {
  case input {
    <<"</params></methodCall>":utf8, rest:bits>> -> Ok(#(reverse(acc, []), rest))
    _ if count >= limits.collection -> Error(Limit)
    <<"<param>":utf8, rest:bits>> -> case value(rest, 1, remaining, limits) {
      Ok(#(v, <<"</param>":utf8, tail:bits>>, n)) ->
        params(tail, n, count + 1, [v, ..acc], limits)
      Error(e) -> Error(e)
      _ -> Error(Unsupported)
    }
    _ -> Error(Unsupported)
  }
}
pub fn decode(input: BitArray, limits: Limits) -> Result(Call, Rejection) {
  case size(input) > limits.bytes || limits.nodes < 1 {
    True -> Error(Limit)
    False -> {
      let raw = case input {
        <<"<?xml version=\"1.0\"?>":utf8, rest:bits>> -> rest
        _ -> input
      }
      case raw {
        <<"<methodCall><methodName>":utf8, rest:bits>> ->
          case text(rest, <<>>, limits.string_bytes) {
            Ok(#(name, <<"</methodName><params>":utf8, tail:bits>>)) if name != <<>> ->
              case params(tail, limits.nodes - 1, 0, [], limits) {
                Ok(#(xs, <<>>)) -> Ok(Call(name, xs))
                Error(e) -> Error(e)
                _ -> Error(Unsupported)
              }
            Ok(#(name, <<"</methodName></methodCall>":utf8>>)) if name != <<>> ->
              Ok(Call(name, []))
            Error(e) -> Error(e)
            _ -> Error(Unsupported)
          }
        _ -> Error(Unsupported)
      }
    }
  }
}

fn text_size(input: BitArray, length: Int, wire: Int, limit: Int)
  -> Result(Int, Rejection) {
  case input {
    <<>> -> Ok(wire)
    _ if length >= limit -> Error(Limit)
    <<b, rest:bits>> if b >= 32 && b <= 126 ->
      text_size(rest, length + 1, wire + case b {
        38 -> 5 60 -> 4 62 -> 4 34 -> 6 39 -> 6 _ -> 1
      }, limit)
    _ -> Error(Unsupported)
  }
}
fn value_size(v: Value, depth: Int, remaining: Int, limits: Limits)
  -> Result(#(Int, Int), Rejection) {
  case depth > limits.depth || remaining <= 0 {
    True -> Error(Limit)
    False -> case v {
      Xint(n) if n >= -2_147_483_648 && n <= 2_147_483_647 ->
        Ok(#(26 + size(decimal(n)), remaining - 1))
      Xint(_) -> Error(Unsupported)
      Xbool(_) -> Ok(#(35, remaining - 1))
      Xstring(s) -> case text_size(s, 0, 0, limits.string_bytes) {
        Ok(n) -> Ok(#(32 + n, remaining - 1))
        Error(e) -> Error(e)
      }
      Xarray(xs) -> list_size(xs, depth + 1, remaining - 1, 0, 43, limits)
      Xstruct(xs) -> member_size(xs, depth + 1, remaining - 1, 0, 32, limits)
    }
  }
}
fn list_size(xs: List(Value), depth: Int, remaining: Int, count: Int, wire: Int,
  limits: Limits) -> Result(#(Int, Int), Rejection) {
  case xs {
    [] -> Ok(#(wire, remaining))
    [_, .._] if count >= limits.collection || wire > limits.bytes -> Error(Limit)
    [v, ..rest] -> case value_size(v, depth, remaining, limits) {
      Ok(#(n, left)) -> list_size(rest, depth, left, count + 1, wire + n, limits)
      Error(e) -> Error(e)
    }
  }
}
fn member_size(xs: List(Member), depth: Int, remaining: Int, count: Int, wire: Int,
  limits: Limits) -> Result(#(Int, Int), Rejection) {
  case xs {
    [] -> Ok(#(wire, remaining))
    [_, .._] if count >= limits.collection || remaining <= 0 || wire > limits.bytes -> Error(Limit)
    [Member(name, v), ..rest] if name != <<>> ->
      case text_size(name, 0, 0, limits.string_bytes), value_size(v, depth, remaining - 1, limits) {
        Ok(a), Ok(#(n, left)) ->
          member_size(rest, depth, left, count + 1, wire + 30 + a + n, limits)
        Error(e), _ -> Error(e)
        _, Error(e) -> Error(e)
      }
    _ -> Error(Unsupported)
  }
}
fn escape(input: BitArray, out: BitArray) -> BitArray {
  case input {
    <<38, rest:bits>> -> escape(rest, <<out:bits, "&amp;":utf8>>)
    <<60, rest:bits>> -> escape(rest, <<out:bits, "&lt;":utf8>>)
    <<62, rest:bits>> -> escape(rest, <<out:bits, "&gt;":utf8>>)
    <<34, rest:bits>> -> escape(rest, <<out:bits, "&quot;":utf8>>)
    <<39, rest:bits>> -> escape(rest, <<out:bits, "&apos;":utf8>>)
    <<b, rest:bits>> -> escape(rest, <<out:bits, b>>)
    _ -> out
  }
}
fn encode_value(v: Value) -> BitArray {
  case v {
    Xint(n) -> <<"<value><int>":utf8, {decimal(n)}:bits, "</int></value>":utf8>>
    Xbool(b) -> <<"<value><boolean>":utf8, {case b { True -> 49 False -> 48 }}, "</boolean></value>":utf8>>
    Xstring(s) -> <<"<value><string>":utf8, {escape(s, <<>>)}:bits, "</string></value>":utf8>>
    Xarray(xs) -> <<"<value><array><data>":utf8, {encode_values(xs, <<>>)}:bits, "</data></array></value>":utf8>>
    Xstruct(xs) -> <<"<value><struct>":utf8, {encode_members(xs, <<>>)}:bits, "</struct></value>":utf8>>
  }
}
fn encode_values(xs: List(Value), out: BitArray) -> BitArray {
  case xs {
    [] -> out
    [v, ..rest] -> encode_values(rest, <<out:bits, {encode_value(v)}:bits>>)
  }
}
fn encode_members(xs: List(Member), out: BitArray) -> BitArray {
  case xs {
    [] -> out
    [Member(n, v), ..rest] -> encode_members(rest, <<out:bits, "<member><name>":utf8,
      {escape(n, <<>>)}:bits, "</name>":utf8, {encode_value(v)}:bits, "</member>":utf8>>)
  }
}
fn encode_params(xs: List(Value), out: BitArray) -> BitArray {
  case xs {
    [] -> out
    [v, ..rest] -> encode_params(rest, <<out:bits, "<param>":utf8,
      {encode_value(v)}:bits, "</param>":utf8>>)
  }
}
fn length(xs: List(a), n: Int) -> Int {
  case xs { [] -> n [_, ..rest] -> length(rest, n + 1) }
}
pub fn encode(model: Call, limits: Limits) -> Result(BitArray, Rejection) {
  let Call(name, xs) = model
  case name == <<>> || limits.nodes < 1 { True -> Error(Unsupported) False -> {
    case text_size(name, 0, 0, limits.string_bytes),
      list_size(xs, 1, limits.nodes - 1, 0, 0, limits) {
      Ok(n), Ok(#(v, _)) -> {
        case 67 + n + v + 15 * length(xs, 0) > limits.bytes {
          True -> Error(Limit)
          False -> {
        let out = <<"<methodCall><methodName>":utf8, {escape(name, <<>>)}:bits,
          "</methodName><params>":utf8, {encode_params(xs, <<>>)}:bits,
          "</params></methodCall>":utf8>>
        case size(out) > limits.bytes { True -> Error(Limit) False -> Ok(out) }
          }
        }
      }
      Error(e), _ -> Error(e)
      _, Error(e) -> Error(e)
    }
  } }
}
pub fn generate(index: Int, method: BitArray, limits: Limits) -> Result(BitArray, Rejection) {
  let xs = case index % 9 {
    0 -> []
    1 -> [Xint(0)]
    2 -> [Xint(-2_147_483_648), Xint(2_147_483_647)]
    3 -> [Xbool(True), Xbool(False)]
    4 -> [Xstring(<<>>), Xstring(<<"<&>\"'":utf8>>)]
    5 -> [Xarray([]), Xstruct([])]
    6 -> [Xarray([Xint(1), Xbool(True), Xstring(<<"abc":utf8>>)])]
    7 -> [Xstruct([Member(<<"key":utf8>>, Xstring(<<"value":utf8>>))])]
    _ -> [Xarray([Xstruct([Member(<<"nested":utf8>>, Xarray([Xint(42)]))])])]
  }
  encode(Call(method, xs), limits)
}
pub fn mutate(model: Call, operation: Int, choice: Int, limits: Limits) -> Result(Call, Rejection) {
  let Call(name, xs) = model
  let n = choice % 257 - 128
  let scalar = case choice % 3 { 0 -> Xint(n) 1 -> Xbool(choice % 2 == 0) _ -> Xstring(<<{65 + choice % 26}>>) }
  let next = case operation {
    0 -> Call(name, case xs { [] -> [scalar] [_, ..rest] -> [scalar, ..rest] })
    1 -> Call(name, [scalar, ..xs])
    2 -> Call(name, case xs { [] -> [] [_, ..rest] -> rest })
    3 -> Call(name, [Xarray(xs)])
    4 -> Call(name, [Xstruct([Member(<<"value":utf8>>, scalar)])])
    5 -> Call(name, reverse(xs, []))
    _ -> model
  }
  case encode(next, limits) { Ok(_) -> Ok(next) Error(e) -> Error(e) }
}
pub fn check(expected: Call, actual: Call) -> Bool { expected == actual }

// Finite observer IDs. Values, names and AST hashes never become identities.
pub fn observe(status: Int, model: Call) -> List(Int) {
  case status {
    0 -> { let Call(_, xs) = model [0, 4, ..features(xs, 0)] }
    1 -> [1]
    2 -> [2]
    _ -> [3]
  }
}
fn count_bucket(xs: List(a), count: Int) -> Int {
  case xs { [] -> count [_, .._] if count >= 3 -> 3 [_, ..rest] -> count_bucket(rest, count + 1) }
}
fn features(xs: List(Value), depth: Int) -> List(Int) {
  let bucket = count_bucket(xs, 0)
  [20 + bucket, 24 + case depth { 0 -> 0 1 -> 1 2 -> 2 _ -> 3 }, ..value_features(xs, depth)]
}
fn value_features(xs: List(Value), depth: Int) -> List(Int) {
  case xs {
    [] -> []
    [v, ..rest] -> {
      let one = case v {
        Xint(n) -> [8, case n == 0 { True -> 16 False -> 17 }]
        Xbool(_) -> [9]
        Xstring(s) -> [10, case s == <<>> { True -> 18 False -> 19 }]
        Xarray(vs) -> [11, ..features(vs, depth + 1)]
        Xstruct(ms) -> [12, 20 + count_bucket(ms, 0), ..member_features(ms, depth + 1)]
      }
      append(one, value_features(rest, depth))
    }
  }
}
fn member_features(xs: List(Member), depth: Int) -> List(Int) {
  case xs {
    [] -> []
    [Member(_, v), ..rest] -> append(value_features([v], depth), member_features(rest, depth))
  }
}
fn append(xs: List(a), ys: List(a)) -> List(a) {
  case xs { [] -> ys [x, ..rest] -> [x, ..append(rest, ys)] }
}
