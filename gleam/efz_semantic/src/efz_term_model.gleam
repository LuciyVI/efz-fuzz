// Shared finite primitives for all configured Erlang term APIs. No API invocation.
pub fn scalar(value: Int, choice: Int, minimum: Int, maximum: Int) -> Int {
  let changed = case choice % 4 { 0 -> value + 1 1 -> value - 1 2 -> 0 _ -> -value }
  case changed < minimum { True -> minimum False ->
    case changed > maximum { True -> maximum False -> changed } }
}
fn classes(values: List(Int), out: List(Int)) -> List(Int) {
  case values { [] -> out [value, ..rest] -> classes(rest, [16 + value, ..out]) }
}
fn bucket(value: Int) -> Int {
  case value { 0 -> 0 1 -> 1 n if n <= 4 -> 2 n if n <= 16 -> 3 _ -> 4 }
}
pub fn observe(status: Int, kinds: List(Int), nodes: Int, depth: Int,
  truncated: Bool, result_class: Int) -> List(Int) {
  classes(kinds, [status, 40 + bucket(nodes), 48 + bucket(depth),
    case truncated { True -> 56 False -> 57 }, 60 + result_class])
}
