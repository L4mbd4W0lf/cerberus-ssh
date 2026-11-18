# Third-party notices

CerberusSSH is licensed under the Apache License 2.0 (see `LICENSE`). It is built on the following software, each under its own licence. The Apache-2.0 components are covered by the text in `LICENSE`; their notices, and the MIT licences of SwiftTerm and SwiftUIIntrospect, follow. Not every component is linked into every build (some are only used by tools or optional features).

| Component | Version | Licence | From |
|---|---|---|---|
| swift-nio-ssh (modified: see "swift-nio-ssh: changes made" below) | 0.15.0 | Apache-2.0 | https://github.com/apple/swift-nio-ssh |
| swift-nio | 2.104.0 | Apache-2.0 | https://github.com/apple/swift-nio |
| swift-crypto (bundles a copy of BoringSSL, see below) | 4.5.2 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-asn1 | 1.7.3 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-atomics | 1.3.1 | Apache-2.0 | https://github.com/apple/swift-atomics |
| swift-collections | 1.7.3 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-system | 1.8.1 | Apache-2.0 | https://github.com/apple/swift-system |
| swift-argument-parser (only in SwiftTerm's termcast tool, not in the app) | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-png (only in SwiftTerm on Linux, Windows and Android, not in the app) | 4.5.1 | Apache-2.0 | https://github.com/tayloraswift/swift-png |
| h (with swift-png, not in the app) | 1.0.1 | Apache-2.0 | https://github.com/rarestype/h |
| SwiftTerm | 1.99.0 | MIT | https://github.com/migueldeicaza/SwiftTerm |
| SwiftUIIntrospect | 27.1.0 | MIT | https://github.com/siteline/swiftui-introspect |

The versions are those the app was built with when this file was written.

## swift-nio-ssh: changes made (Apache-2.0)

The copy of swift-nio-ssh 0.15.0 (upstream commit `3ec2814`) built into CerberusSSH is modified. Upstream's licence is Apache-2.0; its own `NOTICE` and the notices below apply. The changes are additive and, apart from RSA host-key checking, client side only:

1. **Keyboard-interactive authentication** (RFC 4256) for one-time-code logins: new user-auth info request/response messages, a keyboard-interactive offer, and a delegate method with a failing default.
2. **RSA** user keys and host keys (`rsa-sha2-512`, `rsa-sha2-256`, and SHA-1 `ssh-rsa` offered last), using `_CryptoExtras` from swift-crypto.
3. **Older key exchange**: the client side of `diffie-hellman-group14-sha256` and `-sha1`, offered after the elliptic-curve methods, with a small big-integer type and RFC 4253 key derivation for more than one hash block.
4. **Externally signed keys**: a private key whose signing is done by a closure, so a key held by an `ssh-agent` can authenticate a user.

**BoringSSL.** swift-crypto bundles a copy of Google's BoringSSL (the `CCryptoBoringSSL` target), which carries its own licence terms for the code it keeps from OpenSSL and SSLeay. Those terms are in the swift-crypto repository (https://github.com/apple/swift-crypto, `Sources/CCryptoBoringSSL`) and its `NOTICE.txt` below. Before a notarised release is distributed widely, check that the licence text for the bundled BoringSSL is reproduced here in full.

---

## SwiftTerm (MIT)

```
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## SwiftUIIntrospect (MIT)

```
Copyright 2019 Timber Software

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## swift-nio — NOTICE

```

                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:

  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product is heavily influenced by Netty.

  * LICENSE (Apache License 2.0):
    * https://github.com/netty/netty/blob/4.1/LICENSE.txt
  * HOMEPAGE:
    * https://netty.io

---

This product contains NodeJS's llhttp.

  * LICENSE (MIT):
    * https://github.com/nodejs/llhttp/blob/1e1c5b43326494e97cf8244ff57475eb72a1b62c/LICENSE-MIT
  * HOMEPAGE:
    * https://github.com/nodejs/llhttp

---

This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET

  * LICENSE (MIT):
    * https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/lib/cpp_magic.h
  * HOMEPAGE:
    * https://github.com/18sg/uSHET

---

This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project)

  * LICENSE (BSD-3):
    * https://opensource.org/licenses/BSD-3-Clause
  * HOMEPAGE:
    * https://github.com/freebsd/freebsd-src

---

This product contains a derivation of Fabian Fett's 'Base64.swift'.

  * LICENSE (Apache License 2.0):
    * https://github.com/swift-extras/swift-extras-base64/blob/b8af49699d59ad065b801715a5009619100245ca/LICENSE
  * HOMEPAGE:
    * https://github.com/fabianfett/swift-base64-kit

---

This product contains a derivation of "XCTest+AsyncAwait.swift" & "StructuredConcurrencyHelpers" from AsyncHTTPClient.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swift-server/async-http-client

---

This product contains a derivation of "_TinyArray.swift" from SwiftCertificates.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-certificates

---

This product contains a derivation of the mocking infrastructure from Swift System.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-system

---

This product contains a derivation of "TokenBucket.swift" from Swift Package Manager.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swiftlang/swift-package-manager
```

---

## swift-crypto — NOTICE

```
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains test vectors from Google's wycheproof project.

  * LICENSE (Apache License 2.0):
    * https://github.com/C2SP/wycheproof/blob/31387e2cd596587c859c611027b6a44d2e2b65ff/LICENSE
  * HOMEPAGE:
    * https://github.com/google/wycheproof

---

This product contains a derivation of various files from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
```

---

## swift-asn1 — NOTICE

```

                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
    
---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
```

---

## swift-png — NOTICE

```
the `swift-png` package was created by diana ma (@tayloraswift).

you are welcome to contribute to this project at:

    https://github.com/tayloraswift/swift-png

we do not maintain any other mirrors of this repository, and such
forks of this repository may not carry the most up-to-date code.
```

---

## h — NOTICE

```
the `h` package was created by diana ma (@tayloraswift).

you are welcome to contribute to this project at:

    https://github.com/rarestype/h

we do not maintain any other mirrors of this repository, and such
forks of this repository may not carry the most up-to-date code.
```
