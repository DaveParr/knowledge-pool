# MTGJSON Ingestion Mechanics

Research for [DaveParr/knowledge-pool#12](https://github.com/DaveParr/knowledge-pool/issues/12) — grounding the design of the
data-ingestion pipeline for the MTG Commander deckbuilder's LLM+RAG skeleton. MTGJSON is the chosen card-data source (final
decision, not revisited here). This document covers only MTGJSON's ingestion mechanics, sourced from MTGJSON's own site,
GitHub org, and (for the licensing question) Wizards of the Coast's own Fan Content Policy page.

All data pulled 2026-08-22.

---

## 1. Which file(s) to use for ingestion

MTGJSON's [All Files download page](https://mtgjson.com/downloads/all-files/) offers several comprehensive files. The
relevant ones for a Commander deckbuilder:

- **AllPrintings** — "all sets using the Set Data Model," i.e. every printing/variation of every card (Card (Set) model),
  keyed by set code. Contains full print history: set membership, artist, rarity, collector number, border/frame data,
  finishes, promo flags, etc.
- **AllIdentifiers** — all Card (Set) and Card (Token) objects, organized by the card's `uuid` property (one entry per
  printing, not per card name). Useful for direct UUID-keyed lookups.
- **AllPrices** / **AllPricesToday** — pricing data for the last 90 days / today only, keyed by `uuid`. Not needed for
  a rules/oracle-text RAG pipeline; optional if price display is added later.
- **AtomicCards** — every card organized by **name** (Card (Atomic) model), deduplicating printings into one canonical
  rules-text/oracle-data record per card face. This is the "one row per unique card" abstraction — no per-set/artwork
  data, but has `identifiers`, `legalities`, `keywords`, `manaCost`, `manaValue`, `text`, `types`, etc.
- **CardTypes** — reference list of every card type token (per the Card Types Data Model) — not per-card, just the
  vocabulary.
- **Keywords** — reference list of all keyword abilities used across all cards — again vocabulary, not per-card data.
- **Meta** — build metadata only: `date` and `version` (see Q3).
- Format-restricted files (Legacy/Modern/Pioneer/Standard/Vintage/PauperAtomic) — atomic-card subsets pre-filtered to
  cards legal in that format. No equivalent "CommanderAtomic" file exists in this list.

**Recommendation:** Use **AtomicCards** as the primary ingestion source for card names, oracle text, types, mana
costs, keywords, and legalities (`legalities.commander` gives Commander legality directly, one record per unique
card — ideal for RAG/embedding since duplicate printings would otherwise pollute a vector store). Each AtomicCards
record's `identifiers` field already carries `scryfallId`, `scryfallOracleId`, `multiverseId`, `tcgplayerProductId`,
and a dozen other cross-reference IDs (see Q2), so **AllIdentifiers/AllPrintings are not required** just to get those
IDs. Only pull **AllPrintings** (or **AllIdentifiers**) additionally if/when the app needs printing-level data (set
symbol, specific art, collector number) for UI display — e.g. showing which sets a card was printed in, or images via
`scryfallId`.

Sources: [All Files](https://mtgjson.com/downloads/all-files/), [Card (Atomic) model](https://mtgjson.com/data-models/card/card-atomic/), [Card (Set) model](https://mtgjson.com/data-models/card/card-set/), [Identifiers model](https://mtgjson.com/data-models/identifiers/), [Legalities model](https://mtgjson.com/data-models/legalities/)

---

## 2. Schema/format, available formats, file sizes

**Available formats** (per [Getting Started](https://mtgjson.com/getting-started/) and the [All Files page](https://mtgjson.com/downloads/all-files/)): JSON, CSV, Parquet, SQL dump, SQLite, PSQL, plus gzip-compressed variants of most. AllPrintings additionally ships as split-out **AllPrintingsCSVFiles** and **AllPrintingsParquetFiles**.

**Top-level file structure**: every file uses the same envelope — a `meta` object and a `data` object/array. `AllPrintings.json`'s `data` is keyed by set code; `AtomicCards.json`'s `data` is keyed by card name (array of Card (Atomic) objects per name, to account for cards with the same name across editions/errata); `AllIdentifiers.json`'s `data` is keyed by `uuid`. Source: [Getting Started](https://mtgjson.com/getting-started/).

**Measured file sizes** (via `HEAD` request against `mtgjson.com/api/v5/`, 2026-08-22 build):

| File | Format | Size |
|---|---|---|
| AllPrintings.json | uncompressed | 657,351,098 bytes (~627 MB) |
| AllPrintings.json.gz | gzip | 178,185,531 bytes (~170 MB) |
| AllPrintings.sqlite | SQLite | 675,643,392 bytes (~644 MB) |
| AllPrintings.sqlite.gz | gzip | 242,379,437 bytes (~231 MB) |
| AllIdentifiers.json | uncompressed | 635,063,654 bytes (~606 MB) |
| AtomicCards.json | uncompressed | 159,514,820 bytes (~152 MB) |
| AtomicCards.json.gz | gzip | 51,160,989 bytes (~49 MB) |
| SetList.json | uncompressed | 11,590,859 bytes (~11 MB) |
| CardTypes.json | uncompressed | 6,890 bytes |
| Keywords.json | uncompressed | 4,340 bytes |
| Meta.json | uncompressed | 113 bytes |

AtomicCards is roughly a quarter the size of AllPrintings, consistent with it deduplicating per-printing data down to one record per card name — reinforcing it as the right choice for a Commander app's RAG corpus (smaller footprint on a Railway deployment).

**Documented data-model/schema reference**: MTGJSON publishes a full data-models reference under `mtgjson.com/data-models/`, e.g. [Card (Atomic)](https://mtgjson.com/data-models/card/card-atomic/), [Card (Set)](https://mtgjson.com/data-models/card/card-set/), [Meta](https://mtgjson.com/data-models/meta/), [Identifiers](https://mtgjson.com/data-models/identifiers/), [Legalities](https://mtgjson.com/data-models/legalities/), [Set List](https://mtgjson.com/data-models/set-list/). Key fields on Card (Atomic) include `name`, `manaCost`, `manaValue` (formerly `convertedManaCost`, now deprecated), `colors`, `colorIdentity`, `types`/`supertypes`/`subtypes`, `text` (oracle/rules text), `keywords`, `legalities` (a `Legalities` object), `identifiers` (an `Identifiers` object), `rulings`, `printings` (list of set codes), `edhrecRank`/`edhrecSaltiness`, `isGameChanger` (Commander "Game Changer" list flag), and `leadershipSkills` (which formats the card is legal to be a commander in — directly relevant to Commander deckbuilding). Card (Set) additionally layers on `uuid` (MTGJSON v5 UUID, one per specific printing), `setCode`, `rarity`, `artist`, `number`, `finishes`, `variations`, etc.

The `Legalities` model has one string field per format (`commander`, `standard`, `modern`, `legacy`, `pioneer`, `vintage`, `pauper`, `paupercommander`, `oathbreaker`, `predh`, etc.) — Commander is a first-class, ordinary field, `legalities.commander`, with no special encoding versus other formats. Source: [Legalities model](https://mtgjson.com/data-models/legalities/).

The `Identifiers` model (used for cross-referencing) includes `scryfallId`, `scryfallOracleId`, `scryfallIllustrationId`, `scryfallCardBackId`, `multiverseId` (Gatherer), `tcgplayerProductId`, `mtgjsonV4Id`, `mtgoId`, `mtgArenaId`, `cardKingdomId`, `mcmId` (Cardmarket), and several more retailer IDs. Source: [Identifiers model](https://mtgjson.com/data-models/identifiers/).

The `Meta` model is minimal: `date` (ISO 8601 release date of the build) and `version` (SemVer + build date). Source: [Meta model](https://mtgjson.com/data-models/meta/).

---

## 3. Detecting a new MTGJSON release / new set release

- **Build cadence**: MTGJSON's own [FAQ](https://mtgjson.com/faq/) states builds "kick off at 1:00AM EST and go live at 9:00AM EST" (times may shift on upstream issues), and the [GitHub README](https://raw.githubusercontent.com/mtgjson/mtgjson/master/README.md) states plainly: **"We fully rebuild our API data once a day."** This was corroborated empirically: every file checked (`AllPrintings.json`, `AtomicCards.json`, `AllIdentifiers.json`, `SetList.json`, `CardTypes.json`, `Keywords.json`, `Meta.json`) carried the identical `Last-Modified: Sat, 22 Aug 2026 06:1x:xx GMT` timestamp, i.e. all files are rebuilt together as one daily batch (06:11 UTC ≈ their stated overnight EST/EDT build window).
- **Meta file / version**: `Meta.json` (and the `meta` key embedded at the top of every other file) carries `date` (ISO 8601) and `version` (SemVer + build date). The README explicitly recommends this as the detection mechanism: **"You can poll the Meta.json file to see when our data was last updated."** `Meta.json` is tiny (113 bytes measured), making it cheap to poll on a schedule without touching the large bulk files.
- **HTTP headers**: Confirmed via direct `HEAD` requests against `https://mtgjson.com/api/v5/*` — MTGJSON's Cloudflare-fronted server returns standard `ETag`, `Last-Modified`, and `Cache-Control: max-age=57600` (16 hours) headers on every file, and honors `Accept-Ranges: bytes`. This means a conditional-GET (`If-None-Match` / `If-Modified-Since`) against `Meta.json` (or any target file) is a viable, standards-based way to detect a new build without downloading it, as an alternative/supplement to comparing the `version`/`date` fields inside `Meta.json`.
- **Changelog**: MTGJSON publishes a human-readable [MTGJSON v5 Changelog](https://mtgjson.com/changelogs/mtgjson-v5/) using SemVer (MAJOR = architectural change, e.g. new API endpoint or pipeline rewrite; MINOR = new properties/data models; PATCH = bug fixes). Most recent entries at research time: v5.3.0 (2026-02-08, Polars rewrite + expanded pricing), v5.2.2 (2023-09-10), v5.2.1 (2023-02-12). This changelog tracks *schema/pipeline* changes, not day-to-day card-data content updates — new-set detection should rely on `Meta.json`'s `date`/`version`, not the changelog.
- **New set releases specifically**: there is no separate "new set" webhook/RSS feed documented; a new set shows up as part of the next daily rebuild once WotC/partners publish it, discoverable the same way (poll `Meta.json`, or diff `SetList.json`'s set-code list, which is also small at ~11 MB).

Sources: [FAQ](https://mtgjson.com/faq/), [GitHub README](https://raw.githubusercontent.com/mtgjson/mtgjson/master/README.md), [Meta model](https://mtgjson.com/data-models/meta/), [MTGJSON v5 Changelog](https://mtgjson.com/changelogs/mtgjson-v5/), direct `HEAD` requests against `https://mtgjson.com/api/v5/AllPrintings.json`, `AtomicCards.json`, `AllIdentifiers.json`, `SetList.json`, `CardTypes.json`, `Keywords.json`, `Meta.json` (2026-08-22).

---

## 4. Full re-pull vs incremental/delta updates

MTGJSON's own README is explicit that the **published bulk files are a full rebuild, not a delta feed**: *"We fully rebuild our API data once a day."* There is no documented public delta/diff API or changelog-of-card-changes endpoint for consumers — the only granular option is the internal build tooling's `--resume-build` flag (documented in the [GitHub repo](https://github.com/mtgjson/mtgjson)'s CLI options), which lets MTGJSON's own maintainers skip re-scraping individual set files already present in *their* local output directory during a from-scratch build; this is a build-time optimization for MTGJSON's own pipeline, not a consumer-facing incremental-download mechanism. The `-c/--full-build` flag similarly controls whether MTGJSON's own build step regenerates derived outputs like AllPrintings/prices/SQL — again an internal build concern, not something exposed to downstream API consumers.

**Practical implication**: downstream consumers (including this project) should treat every ingestion run as a full re-download of the target file(s), gated by a cheap `Meta.json` check (Q3) to avoid re-downloading when nothing changed. Given the measured sizes (AtomicCards.json.gz ≈ 49 MB, AtomicCards.json ≈ 152 MB uncompressed; AllPrintings.json ≈ 627 MB uncompressed / ≈170 MB gzipped), a Railway-hosted job should always fetch the **gzip-compressed** variant and should schedule pulls no more often than roughly once per day (matching MTGJSON's own build cadence) — e.g. a daily cron checking `Meta.json`'s `date`/`version` (or using conditional `ETag`/`If-Modified-Since` requests, confirmed supported, see Q3) before deciding whether to re-download and re-index AtomicCards.

Sources: [GitHub README](https://raw.githubusercontent.com/mtgjson/mtgjson/master/README.md), [mtgjson/mtgjson repository](https://github.com/mtgjson/mtgjson), file-size measurements above.

---

## 5. Licensing and attribution requirements

**MTGJSON's own license** ([mtgjson.com/license/](https://mtgjson.com/license/)) is a standard **MIT License** (Copyright © 2018–Present, Zach Halpern), covering MTGJSON's own compiled software/data product: permits use, copy, modify, merge, publish, distribute, sublicense, and sell, with no warranty, on the sole condition that "the above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software." This page makes **no mention** of Wizards of the Coast, Scryfall, or a Fan Content Policy — the MIT grant is scoped to MTGJSON's own code/compilation, not to the underlying Magic card text/imagery itself (which remains WotC's copyrighted IP, merely compiled/redistributed by MTGJSON with WotC's/partners' tacit permission as an established community project).

**MTGJSON's own attribution ask** ([Brand Assets](https://mtgjson.com/brand-assets/)) is explicitly **optional, not required**: *"When creating your project a credit to MTGJSON is greatly appreciated, though it is not required."* They ask only that users "not alter the assets or use them in any way that implies MTGJSON endorses you or your project," and provide a "Powered by MTGJSON" logo/badge (PNG/SVG) for those who choose to credit them. The [FAQ](https://mtgjson.com/faq/) confirms MTGJSON is "free and open source under the MIT License" with no cost.

**Card images**: MTGJSON does not host card images itself. Its [FAQ](https://mtgjson.com/faq/) directs consumers to fetch images from Scryfall (via the `scryfallId` identifier) or Gatherer (via `multiverseId`), and explicitly notes: *"If you are serving large amounts of images, Scryfall requests that you cache your own copy."* — i.e. Scryfall's own terms govern image reuse/caching, separately from MTGJSON's license.

**Underlying WotC rights (not an MTGJSON page, but directly applicable)**: because the actual card names/rules text/art are Wizards of the Coast IP, a downstream app built on MTGJSON data is itself "fan content" subject to WotC's own [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy), independent of MTGJSON's MIT grant. That policy requires a notice along the lines of *"[Name of your project] is unofficial Fan Content permitted under the Fan Content Policy. Not approved/endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. ©Wizards of the Coast LLC."*, restricts use of WotC's own logos/trademarks, prohibits monetization mechanisms that gate access (subscriptions/paywalls/required registration — sponsorships/ads/donations are allowed if they don't restrict access), and prohibits verbatim wholesale republishing of WotC's rulebooks/IP (e.g., no proxy/counterfeit card generation). This is WotC's policy, not MTGJSON's — MTGJSON's own site does not itself restate it, so it should be treated as a separate compliance obligation layered on top of MTGJSON's permissive MIT terms.

Sources: [MTGJSON License](https://mtgjson.com/license/), [MTGJSON Brand Assets](https://mtgjson.com/brand-assets/), [MTGJSON FAQ](https://mtgjson.com/faq/), [Wizards of the Coast Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy).

---

## Recommendation summary

Ingest **AtomicCards** (gzip variant, ~49 MB) as the primary corpus — it gives one deduplicated record per card name with oracle text, types, mana cost/value, keywords, `legalities.commander`, `leadershipSkills`, and an `identifiers` block already containing `scryfallId`/`multiverseId`/`tcgplayerProductId` for later cross-referencing, so AllPrintings/AllIdentifiers only need to be added later if printing-level/artwork data becomes necessary. Detect new data by polling the tiny `Meta.json` (113 bytes) on a daily schedule matching MTGJSON's own stated build cadence (builds go live ~9AM EST) and/or issuing a conditional HTTP request (`If-None-Match`/`If-Modified-Since`, both confirmed supported) against the target file before re-downloading; there is no delta/diff API, so every refresh is a full re-fetch of AtomicCards (not the ~627 MB AllPrintings) gated by that cheap version check to avoid unnecessary Railway bandwidth/build time. Bake into the app's footer/about page: MTGJSON attribution is optional but appreciated ("Powered by MTGJSON," MIT-licensed, no restriction on the data itself), while the app should independently carry a Wizards of the Coast Fan Content Policy notice (since the underlying card text/names are WotC IP, not MTGJSON's to relicense) stating the app is unofficial Fan Content, not endorsed by Wizards, with card data "portions of the materials used are property of Wizards of the Coast. © Wizards of the Coast LLC," and should avoid gating access behind payment/registration per that policy.
