# Third-party notices

EFZ's own license remains [Apache-2.0](LICENSE). Optional dependencies retain
their own licenses; this file does not relicense them.

## Erlamsa optional local-data core

Upstream: <https://github.com/Darkkey/erlamsa>

Inspected upstream revision:
`4a844bcd1083e3278c10405bb415a32871b216c3`.

Fork: <https://github.com/LuciyVI/erlamsa>, parent
<https://github.com/Darkkey/erlamsa>, core base
`4a844bcd1083e3278c10405bb415a32871b216c3`, integration commit
`191f3d9d30d8932319b98f4af25d3dff9ddc5824`. EFZ pins the fork through the real
`vendor/erlamsa` submodule; current verification is in
[validation](docs/erlamsa-validation.md).

Erlamsa is MIT-licensed. The fork retains upstream history and its root
`LICENSE`. The `core/` implementation is a bounded EFZ-specific implementation
of selected operator families; it does not copy the upstream JSON or SGML
parser sources. EFZ scheduling and provider wrappers remain in EFZ.

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
