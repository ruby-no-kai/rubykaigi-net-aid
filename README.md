# rubykaigi-net-aid: Central helper tool for RubyKaigi Network Operators

Replaces most of spreadsheet-based operations to a web-based interface.

- Backend: Rails, Protobuf-native with Connect RPC, Runs on AWS Lambda, Persistence on DSQL (standard PostgreSQL on local)
- Frontend: React, Vite, React Router, Kumo UI, useSWR, tanstack form, pnpm, node, serve via S3+CloudFront (SSG).
