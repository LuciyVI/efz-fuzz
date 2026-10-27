# Third-party notices

EFZ's own license remains [Apache-2.0](LICENSE). Optional dependencies retain
their own licenses; this file does not relicense them.

## Erlamsa optional local-data core

Upstream: <https://github.com/Darkkey/erlamsa>

Inspected upstream revision:
`4a844bcd1083e3278c10405bb415a32871b216c3`.

Intended fork: <https://github.com/LuciyVI/erlamsa>, pinned through
`vendor/erlamsa` only after publication/verification. Current status appears in
[validation](docs/erlamsa-validation.md); listing the URL does not assert remote
acceptance has passed.

Erlamsa is MIT-licensed. Its library adaptation retains upstream history and
LICENSE. Adapted JSON/SGML parser and serializer modules preserve their original
copyright/license notices and explicit provenance/modification comments. Byte
and dependent-field implementations also adapt upstream algorithms, retaining
their MIT notices and source references while making randomness and bounds
explicit. EFZ scheduling and provider wrappers remain in EFZ. The byte adapter
also retains the upstream module's Copyright (c) 2014-2019 Alexander Bolshev
aka dark_k3y notice, in addition to the root-license notices below.

The upstream license states:

> Copyright (c) 2011-2014 Aki Helin  
> Copyright (c) 2014-2018 Alexander Bolshev aka dark_k3y
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
> SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
> THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### JSON parser ancestry

The Erlamsa JSON parser credits JSONE's decoder:
<https://github.com/sile/jsone>, Copyright (c) 2013-2016 Takeru Ohta,
`phjgt308@gmail.com`, MIT. The adapted module preserves this attribution and
the MIT permission/disclaimer. No JSONE package is fetched by the core build.

### SGML parser ancestry

The Erlamsa SGML tokenizer credits Mats Cronqvist's `trane` parser:
<https://github.com/massemanet/trane>, Copyright (c) 2010 Mats Cronqvist, MIT.
The adapted module preserves the attribution and MIT permission/disclaimer.
No `trane` package is fetched by the core build.

## Runtime and existing EFZ dependencies

The optional core has no external Rebar dependencies. Compression, checksums,
hashes, and standard functions use the caller's Erlang/OTP installation and its
bundled runtime libraries; no zlib source is copied into EFZ. The Python SDK
uses Python's standard library and embeds neither `pyerlamsa` nor a Python
mutation implementation.

Existing Cowboy, Cowlib, and Ranch dependencies retain the licenses/notices in
their dependency checkouts. This integration does not change their versions or
import them into the core. Additional upstream Erlamsa application dependencies
are not installed or linked by the standalone `core/` project.
