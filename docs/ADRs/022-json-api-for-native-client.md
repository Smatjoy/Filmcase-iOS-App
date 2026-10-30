# ADR 022 — A token-protected JSON API for a native client

**Status**: Accepted
**Date**: 2026-10-30

Extends [ADR 016](016-client-side-camera-transport.md), which put the camera transport on the client and, with it, made the server's camera JSON (`/camera/client-config.json`, `/recipes/<id>/camera-payload.json`) the shared source of truth for what gets written. A native iOS app is a third client of that same data. This records how it reaches the server, and why the browser pages did not have to change to allow it.

---

## Context

Every view in Filmcase returns HTML or an HTMX fragment. The only JSON it serves is the two camera routes from ADR 016, which exist because the browser's WebUSB code needs the encoding tables and a recipe in the camera's write shape. Everything else a client would want to show, the recipe list with its facets, a recipe's settings, collections, cover thumbnails, is reachable only as markup meant for a template.

There is also no authentication. `django.contrib.auth` is installed and nothing uses it. That is a considered position for a browser app on a home network, and `docs/docker.md` says so plainly. It stops being comfortable when the client is a phone: the server is reachable off the LAN over Tailscale, and a phone is the device most likely to be on a network the user does not control.

---

## Problem

Give a native client what it needs to browse recipes and push one to a camera, without scraping HTML, without breaking the browser app, and without ever leaving the server readable by anyone who happens to reach the port.

The browser's WebUSB client is the constraint that shapes the answer. It fetches the two camera JSON routes with a plain `fetch()` and has nowhere to keep a secret: the page is served from the same unauthenticated origin it is fetched from, so any token it held would be one anyone could read from the page.

---

## Decisions

### A read-only JSON API under `/api/v1/`

Plain Django `JsonResponse` views, GET only, built from the same domain queries the HTML views call. The recipe list takes the explorer's own facet parameters and goes through `get_recipe_gallery_data`, so the two cannot disagree about what a filter means; the facet options for the current filters come back in the same response so a client can build the same sidebar. Collections reuse `get_collection_summaries` and `get_collection_detail`. Thumbnails and originals are served by the same function the browser's image route uses.

Recipes carry an `is_favorite` flag, and the list takes `favorite=true`. The data model has no recipe-level favourite: favourites are marked on images. The API derives one, true when any image taken with the recipe is a favourite, because a phone in the field wants "my favourite recipes" and that is the closest thing the library already records. The rule lives in one domain query, `get_favorite_recipe_ids`, so the browser can adopt it unchanged if it ever wants the same filter.

No DRF. The surface is a handful of read-only endpoints over data the domain layer already shapes, and a serializer framework would add a dependency and a second description of every field.

Writes are not part of this. Editing stays in the browser, and the one write the native client performs, to the camera, does not touch the server.

### A static bearer token, `FILMCASE_API_TOKEN`

Every `/api/` request must carry `Authorization: Bearer <token>`, compared with `hmac.compare_digest`. A missing or wrong token is a 401 with `WWW-Authenticate: Bearer`.

This is a single-user homelab reached over a LAN and Tailscale. Accounts, sessions, token issuing and revocation, and OAuth would each be a feature to build and a surface to get wrong, for one person with one phone. A long random value in the environment, entered once in the app and kept in the Keychain, is proportionate. Rotating it is editing one variable and restarting.

It is read from the environment like the other deployment settings and deliberately not registered with constance: a secret does not belong on the settings page or in the database.

### Fail closed when the token is unset

With `FILMCASE_API_TOKEN` empty, every `/api/` request is answered 503 with a body saying why. The default is empty, so a fresh install exposes nothing new until the owner opts in.

The alternative, an open API when no token is configured, is the failure that matters here: the server is reachable off-LAN, and the likeliest way to end up with an open API is to upgrade and not notice a new setting. 503 rather than 401 or 404 because the server is behaving as configured and the fix is on the server, which is what the status says, and the message tells the owner what to set.

The check runs before anything else, including before routing to a record, so an unauthenticated caller cannot tell an existing recipe from a missing one, and an unknown path under `/api/` meets the same check rather than Django's HTML 404.

### The check is a decorator scoped to `/api/`, not middleware

The project has no middleware stack. Wrapping each route where it is declared in `src/interfaces/api/urls.py` keeps the scope visible next to the routes and makes it impossible for the check to reach a browser page. Non-GET methods get a JSON 405; CSRF does not apply to a read-only API.

### The camera JSON is mirrored under `/api/`, not protected where it is

`/api/v1/camera/client-config.json` and `/api/v1/recipes/<id>/camera-payload.json` are the existing `CameraClientConfig` and `RecipeCameraPayload` views, wrapped. They are not copies: the same classes build the same bytes, which the tests assert byte for byte. The encoding logic exists once.

The alternative was to put the token on the existing routes. That would break the browser's WebUSB client, which cannot hold a token (see Problem), for no gain: those routes expose an encoding table and a recipe, both of which the unauthenticated HTML pages already show. So the browser routes are left exactly as they were, and the native client uses the authenticated mirror.

---

## Consequences

### What this buys

The native client gets a stable, documented read surface and the same camera data as the browser, and nothing it needs from the server has to be parsed out of HTML. A server with no token configured is closed to the API rather than open to it. The browser app is unchanged.

### What it costs

**One token, all-or-nothing.** Anyone holding it can read everything the API serves, and revoking it for one device means rotating it for all. That is acceptable for one user and one phone and is the first thing to revisit if that stops being true.

**A second route for each mirrored camera view.** The two views are reachable at two URLs. They are the same code, so they cannot drift, but a future change to either must remember that a client depends on both.

**The token travels as a header over whatever transport the client uses.** Over the Docker install's self-signed HTTPS that is encrypted; over plain HTTP it is not. The native client is expected to pin the server's certificate, and the API does nothing to enforce TLS itself.

### What is deferred

**The HTML UI remains unauthenticated.** This ADR protects only `/api/`. Every browser page, including the Library page that browses the filesystem, is exactly as open as before, and so are the two original camera JSON routes. Anyone who can reach the port can still use the web app, token or not. Closing that needs real authentication for the browser, which has to coexist with the WebUSB client's inability to hold a secret; it is a separate decision and is not made here.

**Writes through the API.** Editing recipes, ratings and collections from the native client would need a decision on CSRF-free authenticated writes and is out of scope.

**Per-device tokens and revocation**, as above.
