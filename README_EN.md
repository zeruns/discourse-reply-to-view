# discourse-reply-to-view

A content-protection plugin for Discourse providing "reply-to-view" and "login-to-view" functionality.
It offers three BBCode tags — `[reply]` / `[login]` / `[reply=N]` — with visibility resolved
**100% server-side**, **zero hidden content stored in the cooked column**, and leak-proofing
across every content outlet: search index, emails, digests, excerpts, and raw exports.

> [中文文档](README.md)

## Links

- Author's blog: <https://blog.zeruns.com/>
- Demo forum: <https://bbs.eeclub.top/>
- This project was developed by AI

## Requirements

- Verified against Discourse **v2026.9.0-latest** (master branch, built 2026-09-16)
- Minimum compatibility: depends on the core markdown-it `md.block.bbcode.ruler` system and the
  `assets/javascripts/**/discourse-markdown/**` plugin rule loading convention
  (roughly Discourse 3.4+, i.e. versions from mid-2024 onward). Older versions are unverified
  and not recommended.
- No Discourse core source files are modified; everything is implemented via official extension APIs.

---

## Changelog

### v1.1.2 (current)

- **Fixed: hidden content directly visible in non-default languages**. When content
  localization is enabled, translations can lose the [reply]/[login] container structure,
  and the translated hidden content was served to non-default-language users via
  `ContentLocalization.translated_post_cooked`. Now, if a post contains hidden marks and
  the requesting user cannot view all blocks, the localized cooked variant is refused
  (falling back to the protected default cooked). Privileged and unlocked users are unaffected.
- Author blog link added to the top of the `enable_rtv` setting description (all 49 languages)
- 6 new localization-leak tests; 79 examples passing in total

### v1.1.1

- Fixed the "reply to view" button not opening the composer (composer.open draftKey contract)
- The two composer insert buttons moved into the "+" options menu; fixed the inserted example
  text showing an untranslated key

### v1.1.0

- `min_trust_level_to_bypass` default changed to **0** (strict reply-to-view; the v1.0.0 default of 1 let TL1+ users see content without replying)
- The two composer insert buttons moved from the toolbar into the "**+**" options menu (alongside "insert table" / "hidden details"); fixed the inserted example text showing an untranslated key
- **Localization**: all 49 languages supported by Discourse are now included (front-end texts + admin setting descriptions and search keywords)
- **Security hardening**: sealed the revision-history diff leak (the raw word-diff at `/posts/:id/revisions/latest` is replaced with a placeholder for non-privileged users)
- The post-reply auto-refresh now updates the post model (Ember reactive re-render, all decorators preserved)
- Added a `rake rtv:rebake` task to rebake historical posts that existed before the plugin was installed

### v1.0.0

- Initial release: [reply] / [login] / [reply=N] tags, server-side permission checks, zero-content cooked, raw outlet sealing, search scrubbing

## 1. BBCode Syntax

| Tag | Meaning |
| --- | --- |
| `[reply]content[/reply]` | Reply-to-view: unlocked according to the site mode |
| `[login]content[/login]` | Login-to-view: visible to any signed-in user (TL0–TL4) |
| `[reply=N]content[/reply]` | Count mode: requires at least N valid replies in the topic (needs `reply_to_view_allow_count` enabled) |

- Arbitrary regular Markdown (code blocks, images, links, lists, etc.) may be nested inside the tags.
- **Two supported forms**: block form (opening/closing tags each on their own line, indentation allowed)
  and single-line form (`[reply]xxx[/reply]` occupying a whole line).
- **Nesting one tag inside the other is forbidden**: with mixed nesting, the inner tag is treated as
  plain content of the outer block and never takes effect on its own.
- Unclosed / malformed forms (other text on the same line, non-positive-integer attributes, etc.)
  are rendered as plain text without any error.

## 2. Visibility Rules

`[login]`: anonymous visitors see a placeholder box with a "Sign in to view" button
(redirects to `/login?redirect_to=<current post URL>`); the trust-level bypass setting
does not apply to this tag.

`[reply]` precedence (highest to lowest):

1. Site admins, site moderators, and category moderators of the post's category
   (requires core `enable_category_group_moderation`): always visible
2. The post author: always visible (shown with a dashed border + notice bar)
3. `min_trust_level_to_bypass`: users at or above this TL see everything directly (0 = disabled)
4. Regular users, according to `reply_to_view_mode`:
   - `any_reply` (default): any valid reply in the topic (not deleted, not hidden) unlocks all `[reply]` content
   - `exact_post`: must reply directly to the floor containing the `[reply]` content;
     for the first post, both "reply to topic" and "reply to post #1" count
5. Count mode (when `reply_to_view_allow_count` is enabled): unlocked once the user's total valid
   replies in the topic reach N for `[reply=N]`

## 3. Security Architecture (Top Priority)

```
raw (BBCode source kept forever; only retrievable by author/admin/moderator)
        │
        ▼  cook stage (markdown-it bbcode rule; no user/post context)
cooked = <div class="rtv-block rtv-reply" data-rtv-type data-rtv-index
              data-rtv-count data-rtv-checksum></div>   ← placeholder container, zero content
        │
        ├─▶ Storage-layer placeholder: post_process_cooked hook bakes a default-locale notice
        │   (covers search index / emails / digests / oneboxes / excerpts / exports / RSS)
        │
        ▼  PostSerializer stage (the ONLY injection point, with user context)
   permission check → inject rendered content (unlocked/owner) or placeholder (locked)
```

- **Alignment check (anti-misalignment)**: at cook time each container receives an FNV-1a checksum
  of the block content (identical JS and Ruby implementations). Before injection, type / count /
  checksum are verified per block; **any mismatch downgrades the entire post to placeholders —
  better to hide everything than to inject into the wrong block**.
- **Raw outlet sealing**: `/posts/:id/raw`, `/raw/:topic_id/:post_number`, revision history, and
  `/posts.json?id=latest` (the `add_raw: true` serialization path) are all sanitized; hidden blocks
  are replaced with a placeholder notice for non-privileged users (including users who already unlocked).
- **Cache safety**: permission checks are computed live with only per-request memoization
  (`ActiveSupport::CurrentAttributes`) — never a cross-request cache. Content unlocks immediately
  after replying, with no window for a low-privilege user to hit a high-privilege cache entry.
  The only cross-request cache is the "rendered block output" (keyed by post version + content
  checksum, user-independent). Anonymous responses render a uniform placeholder version that is
  safe for CDN / shared anonymous caching.
- **XSS protection**: injected content always goes through `Post#cook` (the official Discourse
  Markdown pipeline + allowlist); placeholder texts are i18n text nodes. No HTML is ever assembled
  outside the allowlist.
- **Search scrubbing**: the official `:post_search_index_text` modifier acts as a second line of
  defense (the primary one being zero-content cooked + storage-layer placeholder text).

## 4. Site Settings

After installation, configure under **Admin → Settings → Plugins** (`/admin/site_settings/category/plugins`):

| Setting | Type / Default | Description |
| --- | --- | --- |
| `enable_rtv` | bool / `true` | Master switch. When off, historical marked content is shown as plain text (no box) in rendered views; the switch is reversible |
| `reply_to_view_mode` | enum / `any_reply` | `any_reply` = any reply unlocks / `exact_post` = exact-floor unlock |
| `reply_to_view_allow_count` | bool / `false` | Enables `[reply=N]` count syntax; when off it degrades to plain `[reply]` |
| `min_trust_level_to_bypass` | 0–4 / `0` | TL bypass line, 0 = disabled (default, strict reply-to-view). Raise it if TL1+ users should see content without replying |
| `min_trust_level_to_use` | 0–4 / `1` | Usage permission: tags posted by users below this level have no effect (content is directly visible to everyone), and the composer buttons are hidden for them |

## 5. Installation (Official Docker Deployment)

### Option A: git repository (recommended for production)

Push the plugin to your git repository, then edit `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/zeruns/discourse-reply-to-view.git
```

Then rebuild the container (frontend assets must be recompiled — a rebuild, not a restart):

```bash
cd /var/discourse
./launcher rebuild app
```

### Option B: local directory (temporary testing)

```bash
docker cp /path/to/discourse-reply-to-view app:/var/www/discourse/plugins/
./launcher rebuild app
```

Note: files copied directly into the container are lost on `rebuild`; use Option A for production.

### Verifying the installation

1. Admin → Plugins: confirm `discourse-reply-to-view` is listed and enabled
2. Create a test post:

   ```
   [login]content for signed-in users[/login]

   [reply]content for repliers[/reply]
   ```

3. Open it in an anonymous window: you should see a green (login) and a blue (reply) placeholder box
4. Sign in with another account: the login block is visible while the reply block stays locked;
   after replying to the topic the page refreshes the locked posts in place


## Localization

The plugin ships all 49 languages supported by Discourse (mirroring the core locale list):
front-end placeholders, buttons and notice bars, admin setting descriptions and search keywords
are all translated. Placeholders are rendered per requesting user's locale at serialization
time; channels that read cooked directly (emails, search) use the baked site-default locale text.

## Rebaking Historical Posts

Posts that existed before the plugin was installed have literal tag text in their cooked field.
Rebake them as follows (re-runs the cook pipeline, generating placeholder containers with baked
notices):

```bash
./launcher enter app
rake rtv:rebake
```

Posts created after installation do not need this (they are baked automatically).

## 6. Running the Tests

```bash
# One-time preparation inside the container
docker exec app su - postgres -c "psql -c \"CREATE DATABASE discourse_test OWNER discourse;\""
docker exec app bash -lc "cd /var/www/discourse && bundle config set --local without none && \
  bundle config set --local with test development && bundle install"
docker exec -u discourse app bash -lc "cd /var/www/discourse && \
  LOAD_PLUGINS=1 SKIP_MULTISITE=1 RAILS_ENV=test bin/rails db:migrate"

# Run the full plugin test suite
docker exec -u discourse app bash -lc "cd /var/www/discourse && \
  SKIP_MULTISITE=1 RAILS_ENV=test bin/rspec plugins/discourse-reply-to-view/spec/"
```

Result: 73 examples, 0 failures (stable across multiple randomized-order runs).

Covered scenarios:
- Server-side cooking: placeholder container generation / zero content leakage / count attributes /
  unclosed tags as plain text / nesting semantics / cross-implementation checksum alignment (incl. CJK & emoji)
- Permission matrix: anonymous, signed-in non-replier, replier (any_reply / exact_post / count),
  author, admin, moderator, category moderator (same / other category), TL bypass, usage-threshold
  downgrade, deleted & hidden replies not counted
- Outlet sealing: topic JSON, single-post JSON, all three raw endpoints, the latest stream
  (`add_raw`), search index (tsvector and full-text search), excerpt channel, storage-layer baking,
  and the safe fallback when alignment validation fails

## 7. Upgrades & Compatibility Notes

- **After major Discourse upgrades**: rebuild in a staging environment first and run the test suite
  above. The controller extensions (`markdown` / `markdown_for_topic`, etc.) mirror the core
  implementations; sync them if the core changes those methods.
- **Disabling / uninstalling**: turning off `enable_rtv` immediately shows historical content as
  plain text — no data loss. After fully removing the plugin, BBCode tags in raw render as-is
  (harmless unregistered tags).
- **Localization**: placeholder texts are rendered per requesting user's locale at serialization
  time; channels that read cooked directly (emails, search) use the baked site-default locale text.

## 8. Known Trade-offs

1. The `min_trust_level_to_use` downgrade (tags not taking effect) only applies to serialized
   views; channels reading cooked directly still show the placeholder (conservative direction,
   no leak risk).
2. The composer preview shows content and the notice bar to the author only; it never affects
   server-side rendering.
3. Category-moderator exemption relies on the core `enable_category_group_moderation` setting.
4. The frontend "auto-unlock after reply" is progressive enhancement: locked posts on the page are
   refreshed individually; on failure a full reload resolves it — correctness is unaffected.

## 9. Project Layout

```
discourse-reply-to-view/
├── plugin.rb                       Entry point: settings, prepend registrations, event hooks, search modifier
├── config/
│   ├── settings.yml                5 site settings
│   └── locales/                    server/client × English/Simplified-Chinese i18n
├── assets/
│   ├── javascripts/
│   │   ├── discourse-markdown/     markdown-it rules (official auto-loaded directory, shared by both ends)
│   │   │   ├── server-rtv-rule.js    Server cook rule (drops content, emits checksummed placeholder)
│   │   │   └── client-rtv-rule.js    Client preview rule (renders content + wraps in preview container)
│   │   └── discourse/
│   │       ├── initializers/
│   │       │   └── reply-to-view.js  "+"-menu insert options / placeholder decoration / post-reply refresh
│   │       └── components/
│   │           └── rtv-block.gjs     Placeholder interaction component (login/reply buttons)
│   └── stylesheets/
│       └── common/
│           └── reply-to-view.scss    Blue (reply) / green (login) themes and dashed notice styles
├── lib/
│   └── reply_to_view/
│       ├── current.rb               Request-scoped state (ActiveSupport::CurrentAttributes)
│       ├── engine.rb                Block extraction engine (aligned with the JS bbcode engine + FNV-1a)
│       ├── guard.rb                 Visibility engine (100% server-side)
│       ├── cooked_injector.rb       Serialization-time injector (alignment check + placeholder build)
│       ├── raw_sanitizer.rb         Raw-outlet sanitizer
│       ├── placeholder_baker.rb     Storage-layer placeholder baking + search scrubbing
│       ├── cache.rb                 Cache & invalidation strategy
│       └── extensions.rb            PostSerializer / PostsController prepend extensions
└── spec/                            RSpec (components / lib / requests / services)
```
