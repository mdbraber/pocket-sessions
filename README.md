# Pocket Sessions

Monorepo for the Sessions feature of Pocket Casts:

| Folder | What it is |
|---|---|
| [`ios/`](ios/) | Fork of [Automattic/pocket-casts-ios](https://github.com/Automattic/pocket-casts-ios) with the Sessions feature. Design: [`ios/SESSIONS_SERVER_PLAN.md`](ios/SESSIONS_SERVER_PLAN.md) |
| [`server/`](server/) | The Pocket Casts Sessions server (`pcs`), written in Go. See [`server/README.md`](server/README.md) and [`server/ARCHITECTURE.md`](server/ARCHITECTURE.md) |

Both folders keep their full git history.

## Pulling updates from Automattic

`ios/` was added with `git subtree`, so Automattic's commits keep their
original IDs and upstream merges still find a common ancestor:

```sh
git remote add upstream https://github.com/Automattic/pocket-casts-ios.git
git subtree pull --prefix=ios upstream trunk
```

GitHub Actions workflows under `ios/.github/` do not run from a subfolder.
