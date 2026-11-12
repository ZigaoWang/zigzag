# Third-party notices

Zigzag's code is licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE). It builds
on, bundles, or is tested with the following works by others. Each stays under its own license, listed here
with its attribution. None of them is covered by Zigzag's license.

## Shipped in the app

### Sparkle

Software updates. Linked as a Swift package (`https://github.com/sparkle-project/Sparkle`, version 2.10.0 at
the time of writing; see `Package.resolved`) and embedded in the app as `Sparkle.framework`.

License: MIT, plus the external licenses for the code Sparkle itself includes. The full text, from
[Sparkle's LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE):

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Readability

Reader view. `Zigzag/Resources/Reader/Readability.js` and `Zigzag/Resources/Reader/Readability-readerable.js`
are Mozilla's Readability ([github.com/mozilla/readability](https://github.com/mozilla/readability)), the
engine behind Firefox's reader view, version 0.6.0, bundled unmodified.

```
Copyright (c) 2010 Arc90 Inc
```

License: Apache License, Version 2.0. The notice is kept in each file and in
`Zigzag/Resources/Reader/Readability-LICENSE.md`; the full license text is at
[apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0).

### EasyList and EasyPrivacy

Built-in ad and tracker blocking. `Zigzag/Resources/Blocklists/blocklist.json.lzfse` is made from
[EasyList](https://easylist.to/easylist/easylist.txt) and
[EasyPrivacy](https://easylist.to/easylist/easyprivacy.txt) by The EasyList authors
([easylist.to](https://easylist.to)). `blocklist.info.json` records the list versions it was made from.

License: [Creative Commons Attribution-ShareAlike 3.0 Unported (CC BY-SA 3.0)](https://creativecommons.org/licenses/by-sa/3.0/).
(EasyList is also offered under the GNU GPL v3 or later; Zigzag uses it under CC BY-SA 3.0.)

Changes made: `scripts/update_blocklists.sh` downloads both lists, joins them, converts the filters to WebKit
content-blocker rules, and compresses the result with LZFSE. The converted WebKit content-blocker JSON is an
adaptation of EasyList and EasyPrivacy, and is likewise licensed under CC BY-SA 3.0, not under Zigzag's
license. Zigzag credits the lists in Settings and in About Zigzag › Acknowledgments.

### Ghostery adblocker

Matching the community filter lists below against each site. `Zigzag/Resources/AdEngine/ghostery-adblocker.js` is
[@ghostery/adblocker](https://github.com/ghostery/adblocker) (version 2.20.3) by Ghostery GmbH, with the packages it
uses, bundled unmodified and unminified into one script by `scripts/update_ad_engine.sh`. It runs in a JavaScript
context of its own inside Zigzag; Zigzag's own code talks to it from a separate file
(`Zigzag/Resources/AdEngine/ad-engine.js`), which is Zigzag's, under the Apache License.

```
Copyright (c) 2017-present Ghostery GmbH. All rights reserved.
```

License: [Mozilla Public License, Version 2.0](https://mozilla.org/MPL/2.0/), for @ghostery/adblocker and the
@ghostery and @remusao packages bundled with it; MIT for tldts-core and tldts-experimental (Copyright (c) 2017
Thomas Parisot, 2018 Rémi Berson). The bundled script is the Source Code Form; the full license texts and the list of
bundled packages are in `Zigzag/Resources/AdEngine/ghostery-adblocker-LICENSE.txt`, which ships beside it.

### Public Suffix List

Telling one site from another (which part of an address is the site, as in `bbc.co.uk`).
`Zigzag/Resources/public_suffix_list.txt` is the [Public Suffix List](https://publicsuffix.org) by Mozilla and its
contributors, with comments removed; the source form is at
[publicsuffix.org/list/public_suffix_list.dat](https://publicsuffix.org/list/public_suffix_list.dat).

License: [Mozilla Public License, Version 2.0](https://mozilla.org/MPL/2.0/).

### Top-level domains

Telling an address from a search in the address bar. `Zigzag/Resources/tlds.txt` is the list of top-level domains
published by the [Internet Assigned Numbers Authority](https://www.iana.org/domains/root/db)
([data.iana.org/TLD/tlds-alpha-by-domain.txt](https://data.iana.org/TLD/tlds-alpha-by-domain.txt)), lowercased.
IANA publishes it freely, without restrictions on its use.

## Downloaded by the app, not shipped

Zigzag doesn't include these. Each Mac downloads them from their publishers when Zigzag starts and again as they
expire, as any ad blocker's users do, and keeps them in Zigzag's own folder in Application Support.

### uBlock Origin's filter lists

"uBlock filters", "uBlock filters – Quick fixes" and "uBlock filters – Unbreak", by Raymond Hill and the uBlock
Origin contributors ([github.com/uBlockOrigin/uAssets](https://github.com/uBlockOrigin/uAssets)), downloaded from
uBlock Origin's own addresses (ublockorigin.github.io, ublockorigin.pages.dev, cdn.jsdelivr.net). Zigzag uses their
scriptlet and site-specific hiding filters.

License: [GNU General Public License v3.0](https://github.com/uBlockOrigin/uAssets/blob/master/LICENSE).

### uBlock Origin's scriptlets

The scriptlets those lists name, from [uBlock Origin](https://github.com/gorhill/uBlock) by Raymond Hill, as Ghostery
publishes them for its engine (cdn.ghostery.com/adblocker/resources/ublock-resources-json). Zigzag checks each
download against the SHA-256 Ghostery names it by, and runs them in the pages the lists name.

License: [GNU General Public License v3.0](https://github.com/gorhill/uBlock/blob/master/LICENSE.txt).

## Used to build, not shipped

### SafariConverterLib

`scripts/update_blocklists.sh` downloads and builds AdGuard's
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) (v4.3.1) as a separate command-line
tool to convert the filter lists. It's licensed under GPL-3.0. None of its code is in this repository or in the
app; only the rules it outputs (above) ship.

### XcodeGen

[XcodeGen](https://github.com/yonaskolb/XcodeGen) generates `Zigzag.xcodeproj` from `project.yml`. MIT
license. A build tool only.

## Test fixtures, not shipped

### custom-progress-bar.crx

`ZigzagTests/Fixtures/custom-progress-bar.crx` is an unmodified copy of the Chrome Web Store package for
"Custom Progress Bar for YouTube" (version 4.0.25, extension ID `nbkomboflhdlliegkaiepilnfmophgfg`, by
[custom-progressbar.com](https://custom-progressbar.com)). It's used only by `CRXPackageTests` to check that a
genuinely signed store package is accepted and a tampered one refused. It belongs to its authors, is not
covered by Zigzag's license, and is not part of the app. "YouTube" is a trademark of Google LLC. It isn't in this repository: the tests that use it are skipped without it.

### firefox-profile

`ZigzagTests/Fixtures/firefox-profile` is synthetic: `scripts/make_firefox_fixture.py` writes it from NSS's
documented formats, with one made-up login. It contains no third-party code or real data.

## Names and marks

Zigzag mentions other browsers (Arc, Chrome, Safari, Firefox, Zen, Edge, Brave, Dia, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium) to import
from them, and popular websites in onboarding and site search. The bundled `Zigzag/Resources/Onboarding/avoidxray.png`
is the logo of AvoidXray, which is also made by Zigao Wang; it's used to show that site in onboarding. Some site
icons are loaded from their owners' servers when shown. These names, logos and icons belong to their owners; their use here doesn't mean an
endorsement, and they aren't covered by Zigzag's license.
