// Byte-oriented model. No target execution, randomness, corpus or global state.
pub type Field { Field(key: BitArray, value: BitArray) }
pub type Wire { Canonical BadEscape }
pub type Query { Query(fields: List(Field), wire: Wire) }
pub type Limits { Limits(bytes: Int, fields: Int, component: Int, operations: Int) }
pub type Rejection { Unsupported Limit }

@external(erlang, "erlang", "bit_size")
fn bits(value: BitArray) -> Int

pub fn versions() -> #(Int, Int, Int, Int, Int, Int) { #(1, 1, 1, 1, 1, 1) }
// Cold-path catalogue version; runtime model/codec/mutation semantics stay v1.
pub fn generator_version() -> Int { 2 }
pub fn normalize(model: Query) -> Query { model }

fn reverse(xs: List(a), acc: List(a)) -> List(a) {
  case xs { [] -> acc [x, ..rest] -> reverse(rest, [x, ..acc]) }
}

pub fn decode(input: BitArray, limits: Limits) -> Result(Query, Rejection) {
  case bits(input) % 8 == 0 && bits(input) <= limits.bytes * 8 {
    False -> Error(Limit)
    True -> case input {
      <<>> -> Ok(Query([], Canonical))
      _ -> segments(input, <<>>, [], 0, limits)
    }
  }
}

fn segments(input: BitArray, part: BitArray, acc: List(Field), count: Int,
  limits: Limits) -> Result(Query, Rejection) {
  case count >= limits.fields {
    True -> Error(Limit)
    False -> case input {
      <<>> -> case field(part, limits) {
        Error(e) -> Error(e)
        Ok(f) -> Ok(Query(reverse([f, ..acc], []), Canonical))
      }
      <<38, rest:bits>> -> case field(part, limits) {
        Error(e) -> Error(e)
        Ok(f) -> segments(rest, <<>>, [f, ..acc], count + 1, limits)
      }
      <<byte, rest:bits>> -> segments(rest, <<part:bits, byte>>, acc, count, limits)
      _ -> Error(Unsupported)
    }
  }
}

fn field(input: BitArray, limits: Limits) -> Result(Field, Rejection) {
  split_equal(input, <<>>, limits)
}
fn split_equal(input: BitArray, key: BitArray, limits: Limits) -> Result(Field, Rejection) {
  case input {
    <<61, _:bits>> if key == <<>> -> Error(Unsupported)
    <<61, rest:bits>> if key != <<>> -> case unescape(key, <<>>, 0, limits.component),
      unescape(rest, <<>>, 0, limits.component) {
      Ok(k), Ok(v) -> Ok(Field(k, v))
      Error(e), _ -> Error(e)
      _, Error(e) -> Error(e)
    }
    <<b, rest:bits>> -> split_equal(rest, <<key:bits, b>>, limits)
    _ -> Error(Unsupported)
  }
}
fn hex(b: Int) -> Result(Int, Rejection) {
  case b {
    b if b >= 48 && b <= 57 -> Ok(b - 48)
    b if b >= 65 && b <= 70 -> Ok(b - 55)
    b if b >= 97 && b <= 102 -> Ok(b - 87)
    _ -> Error(Unsupported)
  }
}
fn unescape(input: BitArray, out: BitArray, n: Int, max: Int) -> Result(BitArray, Rejection) {
  case input {
    <<>> -> Ok(out)
    _ if n >= max -> Error(Limit)
    <<37, a, b, rest:bits>> -> case hex(a), hex(b) {
      Ok(x), Ok(y) -> unescape(rest, <<out:bits, {x * 16 + y}>>, n + 1, max)
      _, _ -> Error(Unsupported)
    }
    <<37, _:bits>> -> Error(Unsupported)
    <<43, rest:bits>> -> unescape(rest, <<out:bits, 32>>, n + 1, max)
    <<b, rest:bits>> -> unescape(rest, <<out:bits, b>>, n + 1, max)
    _ -> Error(Unsupported)
  }
}
fn safe(b: Int) -> Bool {
  b >= 65 && b <= 90 || b >= 97 && b <= 122 || b >= 48 && b <= 57
    || b == 45 || b == 46 || b == 95 || b == 126
}
fn encoded_size(input: BitArray, n: Int) -> Int {
  case input { <<b, rest:bits>> -> encoded_size(rest, n + case safe(b) { True -> 1 False -> 3 })
    _ -> n }
}
fn model_size(fields: List(Field), n: Int, count: Int, limits: Limits) -> Result(Int, Rejection) {
  case fields {
    [] -> Ok(n)
    [Field(k, v), ..rest] -> case count >= limits.fields || bits(k) == 0
      || bits(k) % 8 != 0 || bits(v) % 8 != 0
      || bits(k) > limits.component * 8 || bits(v) > limits.component * 8 {
      True -> Error(Limit)
      False -> {
        let next = n + encoded_size(k, 0) + encoded_size(v, 0) + 1
          + case count == 0 { True -> 0 False -> 1 }
        case next > limits.bytes { True -> Error(Limit)
          False -> model_size(rest, next, count + 1, limits) }
      }
    }
  }
}
fn digit(x: Int) -> Int { case x < 10 { True -> x + 48 False -> x + 55 } }
fn escape(input: BitArray, out: BitArray) -> BitArray {
  case input {
    <<b, rest:bits>> -> case safe(b) {
      True -> escape(rest, <<out:bits, b>>)
      False -> escape(rest, <<out:bits, 37, {digit(b / 16)}, {digit(b % 16)}>>)
    }
    _ -> out
  }
}
fn encode_fields(fields: List(Field), out: BitArray, first: Bool) -> BitArray {
  case fields {
    [] -> out
    [Field(k, v), ..rest] -> {
      let prefix = case first { True -> out False -> <<out:bits, 38>> }
      let key = escape(k, prefix)
      let value = escape(v, <<key:bits, 61>>)
      encode_fields(rest, value, False)
    }
  }
}
pub fn encode(model: Query, limits: Limits) -> Result(BitArray, Rejection) {
  let Query(fields, wire) = model
  case wire_size(model, limits) {
    Error(e) -> Error(e)
    Ok(_) -> case wire {
      Canonical -> Ok(encode_fields(fields, <<>>, True))
      BadEscape -> Ok(<<{encode_fields(fields, <<>>, True)}:bits, 38, 120, 61, 37>>)
    }
  }
}
fn wire_size(model: Query, limits: Limits) -> Result(Int, Rejection) {
  let Query(fields, wire) = model
  case model_size(fields, 0, 0, limits) {
    Error(e) -> Error(e)
    Ok(size) -> {
      let total = size + case wire { Canonical -> 0 BadEscape -> 4 }
      case total <= limits.bytes { True -> Ok(total) False -> Error(Limit) }
    }
  }
}
fn repeated_byte(n: Int, byte: Int, acc: BitArray) -> BitArray {
  case n { 0 -> acc _ -> repeated_byte(n - 1, byte, <<acc:bits, byte>>) }
}
fn repeated_field(n: Int, field: Field, acc: List(Field)) -> List(Field) {
  case n { 0 -> acc _ -> repeated_field(n - 1, field, [field, ..acc]) }
}
// Check catalogue allocation bounds before constructing large components/lists.
fn catalogue_room(index: Int, limits: Limits) -> Bool {
  case index {
    6 -> limits.component >= 128 && limits.bytes >= 386
    7 -> limits.component >= 127 && limits.bytes >= 383
    8 -> limits.fields >= 32 && limits.bytes >= 95
    9 -> limits.fields >= 31 && limits.bytes >= 92
    10 -> limits.component >= 128 && limits.fields >= 16 && limits.bytes >= 4096
    11 -> limits.component >= 128 && limits.bytes >= 257
    _ -> True
  }
}
pub fn generate(index: Int, limits: Limits) -> Result(BitArray, Rejection) {
  let slot = index % 12
  case catalogue_room(slot, limits) {
    False -> Error(Limit)
    True -> {
  let model = case slot {
    0 -> Query([], Canonical)
    1 -> Query([Field(<<97>>, <<>>)], Canonical)
    2 -> Query([Field(<<97>>, <<0, 255>>)], Canonical)
    3 -> Query([Field(<<97>>, <<32, 38, 61, 37>>), Field(<<97>>, <<49>>)], Canonical)
    4 -> Query([Field(<<98, 117, 103>>, <<49>>)], Canonical)
    5 -> Query([Field(<<97>>, <<49>>)], BadEscape)
    6 -> Query([Field(<<97>>, repeated_byte(128, 255, <<>>))], Canonical)
    7 -> Query([Field(<<97>>, repeated_byte(127, 255, <<>>))], Canonical)
    8 -> Query(repeated_field(32, Field(<<97>>, <<>>), []), Canonical)
    9 -> Query(repeated_field(31, Field(<<97>>, <<>>), []), Canonical)
    10 -> {
      let value = repeated_byte(128, 118, <<>>)
      Query([Field(repeated_byte(127, 107, <<>>), value),
        ..repeated_field(15, Field(repeated_byte(126, 107, <<>>), value), [])], Canonical)
    }
    _ -> Query([Field(repeated_byte(128, 107, <<>>), repeated_byte(128, 118, <<>>))], Canonical)
  }
  encode(model, limits)
  } }
}
fn prepend_room(fields: List(Field), remaining: Int) -> Bool {
  case fields {
    [] -> remaining > 0
    [_, .._] if remaining <= 1 -> False
    [_, ..rest] -> prepend_room(rest, remaining - 1)
  }
}
fn mutation_room(fields: List(Field), operation: Int, limits: Limits) -> Bool {
  case operation, fields {
    0, _ -> limits.component >= 2 && prepend_room(fields, limits.fields)
    4, [Field(_, value), .._] -> bits(value) + 8 <= limits.component * 8
    _, _ -> True
  }
}
pub fn mutate(model: Query, operation: Int, limits: Limits) -> Result(Query, Rejection) {
  let Query(fields, _) = model
  case limits.operations < 1 || !mutation_room(fields, operation, limits) {
    True -> Error(Limit) False -> {
    let next = case operation {
      0 -> Query([Field(<<120>>, <<0, 255>>), ..fields], Canonical)
      1 -> Query(case fields { [] -> [Field(<<97>>, <<>>)] [Field(k, _), ..rest] -> [Field(k, <<>>), ..rest] }, Canonical)
      2 -> Query(case fields { [] -> [] [_, ..rest] -> rest }, Canonical)
      3 -> Query(reverse(fields, []), Canonical)
      4 -> Query(case fields { [] -> [Field(<<97>>, <<255>>)] [Field(k, v), ..rest] -> [Field(k, <<v:bits, 255>>), ..rest] }, Canonical)
      5 -> Query(fields, BadEscape)
      _ -> model
    }
    case wire_size(next, limits) { Ok(_) -> Ok(next) Error(e) -> Error(e) }
  } }
}

// Finite vocabulary: acceptance, count bucket, empty values, non-UTF8 bytes.
pub fn observe(status: Int, count: Int, empty: Bool, binary_value: Bool) -> List(Int) {
  case status {
    0 -> [0, 4 + case count { 0 -> 0 1 -> 1 2 -> 2 _ -> 3 },
      case empty { True -> 8 False -> 9 }, case binary_value { True -> 10 False -> 11 }]
    1 -> [1]
    2 -> [2]
    _ -> [3]
  }
}

pub fn check(model: Query, actual: List(Field)) -> Bool {
  let Query(expected, _) = model
  expected == actual
}
