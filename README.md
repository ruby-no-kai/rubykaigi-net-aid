# rubykaigi-net-aid: Central helper tool for RubyKaigi Network Operators

Replaces most of spreadsheet-based operations to a web-based interface.

- Backend: Rails, Protobuf-native with Connect RPC, Runs on AWS Lambda, Persistence on DSQL (standard PostgreSQL on local)
- Frontend: TypeScript, React, Vite, React Router, Kumo UI, useSWR?, MobX?, IndexedDB?, tanstack form, pnpm, node, serve via S3+CloudFront (SSG).

## Local-first app

Take design principle of _local-first._ /home/sorah/git/github.com/wzhudev/reverse-linear-sync-engine
https://marknotfound.com/posts/reverse-engineering-linears-sync-magic/
https://www.youtube.com/live/Wo2m3jaJixU

Establish a common pattern to manipulate or hydrate data on/from Rails backend (common RPC pattern per model).

