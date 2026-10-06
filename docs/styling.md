# Dashboard styling and cache-safe assets

The dashboard uses **Tailwind CSS v4.1.12**, matching ServiceRadar's current pin. The standalone Linux compiler is verified by SHA-256 in Bazel and Docker. Tailwind and esbuild run at build time; the runtime image serves compiled assets.

`web/assets/app.css` is the CSS-first entrypoint. It explicitly registers `web/lib/agentboard_web` and `app.js` as sources. Keep complete utility names in HEEx so Tailwind can discover them. `@theme inline` maps the existing light/dark tokens to utilities such as `bg-paper`, `text-ink`, and `border-line`. Product components live in the components layer and use `@apply`; the later utilities layer can refine them. The seven-column Kanban layout, compact Done cards, quota modal and captain settings retain their established geometry.

Bazel builds `//web:styles` and bundles JavaScript with `//web:assets`. Docker runs the same pinned Tailwind CLI before esbuild. The shared Mix release step invokes Phoenix's native digester before assembly, retaining the original logical assets plus content-fingerprinted files and `cache_manifest.json`. Only manifest wall-clock metadata is normalized for reproducible archives. Phoenix reads this manifest in production; the layout uses `AgentboardWeb.Endpoint.static_path/1` for both CSS and JavaScript.

A stylesheet change produces a new URL, so a browser that cached the previous release requests the new CSS on ordinary navigation. Fingerprinted URLs use long-lived caching; logical URLs continue to support ETag revalidation. No hard refresh should be needed after a release.

All compilation for this repository happens remotely. Use `./scripts/bazel build //web:release` and `./scripts/bazel test //build/integration:image_startup_test`; Docker builds run in CI. The image test consumes the actual rendered HTML, fetches fingerprinted CSS/JS, verifies content hashes and caching headers, and exercises conditional requests on logical paths.

[Interactive asset delivery architecture](architecture/tailwind-v4.html) · [source specification](architecture/tailwind-v4.architecture.json)
