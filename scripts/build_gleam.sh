#!/bin/sh
set -eu
# Opt-in profile only. Do not install/update a compiler or invoke generated .erl.
gleam_exec=${GLEAM_BIN:-gleam}
test "$("$gleam_exec" --version)" = 'gleam 1.10.0' || {
  echo 'EFZ requires pinned Gleam 1.10.0; set GLEAM_BIN to its executable.' >&2
  exit 1
}
project_root=$(pwd)
(cd gleam/efz_semantic && "$gleam_exec" export erlang-shipment)
dest=${REBAR_BUILD_DIR:-$project_root/_build/gleam}/lib/efz/ebin
mkdir -p "$dest"
shipment=gleam/efz_semantic/build/erlang-shipment/efz_semantic/ebin
# EFZ calls the model directly. Gleam's generated command-line launcher is not
# part of this runtime and references optional stdlib inspection helpers.
cp "$shipment/efz_qs_model.beam" "$dest/"
if test -f "$dest/efz_semantic@@main.beam"; then
  inactive_dir=$(mktemp -d "${REBAR_BUILD_DIR:-$project_root/_build/gleam}/gleam-unused.XXXXXX")
  mv "$dest/efz_semantic@@main.beam" "$inactive_dir/"
fi
erl -noshell -eval '
  [Source, Destination] = init:get_plain_arguments(),
  {ok, [{application, efz_semantic, Props}]} = file:consult(Source),
  true = lists:sort(proplists:get_value(modules, Props)) =:= [efz_qs_model, efz_semantic@@main],
  [] = proplists:get_value(applications, Props),
  Runtime = {application, efz_semantic, lists:keyreplace(modules, 1, Props, {modules, [efz_qs_model]})},
  ok = file:write_file(Destination, io_lib:format("~tp.~n", [Runtime])),
  halt().
' -extra "$shipment/efz_semantic.app" "$dest/efz_semantic.app"
echo "EFZ optional Gleam BEAM output: $dest"
