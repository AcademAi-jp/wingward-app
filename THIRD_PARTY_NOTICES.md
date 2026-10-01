# Third-party dependencies

WingWard uses third-party packages under their own licenses. The project AGPL
does not replace those licenses or notices. Dependencies are downloaded by the
package managers; their source code is not vendored in this repository. Preserve
their notices when building or distributing the app.

## Pinned Swift packages

| Package | Version | License / notices at the pinned source revision |
| --- | --- | --- |
| client-sdk-swift | 2.16.0 | [LICENSE](https://github.com/livekit/client-sdk-swift/blob/79fb2beee98e45556bffebefa50b5d05c3382af1/LICENSE), [NOTICE](https://github.com/livekit/client-sdk-swift/blob/79fb2beee98e45556bffebefa50b5d05c3382af1/NOTICE) |
| elevenlabs-swift-sdk | 3.2.2 | [LICENSE](https://github.com/elevenlabs/elevenlabs-swift-sdk/blob/1a66b950ffb36ee0ed4ab9d74ca4f7a5ff641454/LICENSE) |
| livekit-uniffi-xcframework | 0.0.6 | [LICENSE](https://github.com/livekit/livekit-uniffi-xcframework/blob/7c161254ce7cd55debc48023f69a917076b12a26/LICENSE) |
| purchases-ios-spm | 5.88.0 | [LICENSE](https://github.com/RevenueCat/purchases-ios-spm/blob/b5c4652249754d6d8ec415a6bc79a611ea38c839/LICENSE) |
| supabase-swift | 2.54.1 | [LICENSE](https://github.com/supabase/supabase-swift/blob/b118484ae0eb4a6b6ce1b216711d660baf6ec1aa/LICENSE) |
| swift-asn1 | 1.7.1 | [NOTICE.txt](https://github.com/apple/swift-asn1/blob/a9a5efd40eaf558a2bcd48d64b1d1646be686008/NOTICE.txt), [LICENSE.txt](https://github.com/apple/swift-asn1/blob/a9a5efd40eaf558a2bcd48d64b1d1646be686008/LICENSE.txt) |
| swift-clocks | 1.1.0 | [LICENSE](https://github.com/pointfreeco/swift-clocks/blob/72d749bf341b78851203066ab421869b783ec42a/LICENSE) |
| swift-concurrency-extras | 1.4.1 | [LICENSE](https://github.com/pointfreeco/swift-concurrency-extras/blob/5fa253428866f2360c3754e88537f700ed2656b5/LICENSE) |
| swift-crypto | 4.5.1 | [NOTICE.txt](https://github.com/apple/swift-crypto/blob/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6/NOTICE.txt), [LICENSE.txt](https://github.com/apple/swift-crypto/blob/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6/LICENSE.txt) |
| swift-http-types | 1.6.0 | [NOTICE.txt](https://github.com/apple/swift-http-types/blob/db774a277f60063a32d854f2980299caf06da041/NOTICE.txt), [LICENSE.txt](https://github.com/apple/swift-http-types/blob/db774a277f60063a32d854f2980299caf06da041/LICENSE.txt) |
| swift-protobuf | 1.38.1 | [LICENSE.txt](https://github.com/apple/swift-protobuf/blob/55d7a1cc5666b85c13464aea1c4b4a90feccb4c8/LICENSE.txt) |
| webrtc-xcframework | 144.7559.11 | [LICENSE](https://github.com/livekit/webrtc-xcframework/blob/46f2af86f06b9a8a9158d37cadda5cb5a214e4c4/LICENSE) |
| xctest-dynamic-overlay | 1.11.0 | [LICENSE](https://github.com/pointfreeco/xctest-dynamic-overlay/blob/8f6abcf4c8950e2679d5b2fee4ca284fd7c34886/LICENSE) |

## API production dependencies

Installed versions were checked against the frozen dependency tree.

| Package | Version | License |
| --- | --- | --- |
| `@hono/node-server` | 1.19.1 | MIT |
| `@mistralai/mistralai` | 1.14.1 | Apache-2.0 (installed LICENSE) |
| `@supabase/auth-js` | 2.98.0 | MIT |
| `@supabase/functions-js` | 2.98.0 | MIT |
| `@supabase/postgrest-js` | 2.98.0 | MIT |
| `@supabase/realtime-js` | 2.98.0 | MIT |
| `@supabase/storage-js` | 2.98.0 | MIT |
| `@supabase/supabase-js` | 2.98.0 | MIT |
| `@types/node` | 24.3.1 | MIT |
| `@types/phoenix` | 1.6.7 | MIT |
| `@types/ws` | 8.18.1 | MIT |
| `dotenv` | 16.6.1 | BSD-2-Clause |
| `hono` | 4.9.6 | MIT |
| `iceberg-js` | 0.8.1 | MIT |
| `tslib` | 2.8.1 | 0BSD |
| `undici-types` | 7.10.0 | MIT |
| `ws` | 8.18.3 | MIT |
| `zod` | 3.25.76 | MIT |
| `zod-to-json-schema` | 3.25.1 | ISC |

The Mistral package omits the license field in package metadata; its installed
LICENSE contains Apache License 2.0. Swift license/notice files were checked in
local checkouts at exactly the revisions recorded in Package.resolved.
This inventory does not certify ownership of WingWard artwork or contributors’
work; contributors must have the necessary rights to license their contributions.
