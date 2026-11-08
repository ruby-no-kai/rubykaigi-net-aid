# API

The backend serves [Connect](https://connectrpc.com/) unary RPCs from Rails. The `.proto` files under `proto/` are the schema of record: requests, responses and errors are generated messages, never Hash literals.

| Concern | Where |
|---|---|
| Schema | `proto/rubykaigi/net_aid/*.proto`, package `rubykaigi.net_aid`, Ruby namespace `Rk::NetAid` |
| buf configuration | `buf.yaml`, `buf.gen.yaml`, `buf.lock` (repo root) |
| Generated Ruby + RBS | `backend/gen/proto/ruby/`, loaded as the `net_aid-proto` path gem |
| Vendored protos | `proto/protobufable/`, copied from the protobufable gem |
| Connect controllers | `backend/app/controllers/api/<service>/` |
| Response builders | `backend/app/resources/api/` (Alba) |
| Problem catalogue | `proto/rubykaigi/net_aid/problem.proto`, `backend/app/models/errors.rb` |

The stack:

- [connect_rpc_rails](https://github.com/ivry-inc/connect_rpc_rails): Connect RPCs as `ActionController::API` actions, routed from the service descriptor.
- [protobufable](https://github.com/sorah/protobufable): problem catalogue in a protobuf enum, Connect error rendering for problems, Alba resources bound to messages, messages in columns.
- [protovalidate](https://github.com/sorah/protovalidate-rb): `buf.validate` rules on requests.
- [problem](https://github.com/sorah/problem): RFC 9457 problem details.

## Generating code

```sh
mise run gen          # buf build, buf generate, then tapioca dsl --only=Protobuf
mise run lint:proto   # buf lint and buf format
```

Generated files are committed. Regenerate after every `.proto` edit, comment-only ones included.

- `buf build` runs first, so a `.proto` that does not compile leaves `gen/` untouched.
- buf and protoc are pinned in `mise.toml`. protoc must match the `google-protobuf` gem in `backend/Gemfile.lock`; bump both together.
- The `buf.build/bufbuild/protovalidate` dependency is pinned to the release the protovalidate gem bundles (`Protovalidate::PROTOVALIDATE_VERSION`).
- Message classes cannot reload (a duplicate descriptor raises), so they load once through Bundler. Restart the Rails server after regenerating.
- `proto/protobufable/` is excluded from Ruby generation, because the gem ships its own Ruby for it and a second copy fails boot. Refresh it from the gem when protobufable is upgraded.

Proto doc comments are documentation for API clients; write them for that reader.

## Adding an RPC

1. Declare the RPC and its messages in `proto/rubykaigi/net_aid/<service>.proto`. Name request and response `<Service><Method>Request` / `<Service><Method>Response`. Mark RPCs free of side effects with `option idempotency_level = NO_SIDE_EFFECTS;` so clients may use GET; everything else is POST only.
2. `mise run gen`.
3. Route it in `backend/config/routes.rb`, one `connect_service` block per service:

   ```ruby
   connect_service "rubykaigi.net_aid.ViewerService" do
     rpc "GetViewer" => "api/viewer/viewers"
   end
   ```

4. Implement one action per RPC, in snake case, taking no arguments and returning the response message. The controller inherits from the service's base controller (`Api::<Service>::ApplicationController`), which calls `connect_service`.

   ```ruby
   #: () -> Rk::NetAid::ViewerServiceGetViewerResponse
   def get_viewer
     Rk::NetAid::ViewerServiceGetViewerResponse.new(viewer: Rk::NetAid::Viewer.new(signed_in: false))
   end
   ```

- Keep actions thin: read `connect_request`, look up, save, build the response.
- `connect_request` is untyped under Sorbet. Read each field into a typed local: `slug = connect_request.slug #: String`.
- A Create or Update request carries its `<Resource>Input` in a field named `input`. Copy Input fields to attributes explicitly and call `save!`/`update!`; `ActiveRecord::RecordInvalid` becomes the invalid-record problem with violations on `input.*` fields.
- Build response messages through an Alba resource inheriting `Api::ApplicationResource` and bound with `with_protobuf`, which raises at load time when the resource and message disagree. Timestamp fields use the registered `:timestamp` type.

## Request validation

Write rules on the field with `buf.validate`. For a rule whose message a person reads, use a CEL rule with a stable `id`; the `id` becomes the `reason` a client sees and is never reused.

```proto
string name = 1 [(buf.validate.field).cel = {
  id: "device.name.not_blank"
  message: "value must not be blank"
  expression: "this.trim() != ''"
}];
```

A violation is answered `invalid_argument` with a `google.rpc.BadRequest`. `Protovalidate.register_all` runs at boot, so a broken CEL expression fails startup. Rules that need the database stay as model validations.

## Errors

Raise an error class from `Errors` (`backend/app/models/errors.rb`) with a `detail:` naming the specific thing:

```ruby
raise Errors::NotFound.new(detail: "No device has the name #{name.inspect}.")
```

- Each class names a value of `ProblemType` in `problem.proto`, which carries the published `uri` and HTTP status. A typo fails boot.
- Over Connect, the status maps to a Connect code, and a packed `protobufable.ProblemDetails` goes in `details`. Clients dispatch on its `type` (`https://aid.rubykaigi.net/problems/<uri>`); enum names never go on the wire.
- Every Connect error also carries a `google.rpc.RequestInfo` with the request ID.
- An exception that is not a problem is answered with its status text only, never its message.
- Exceptions escaping before a controller runs are answered in the Connect error shape by `ConnectExceptions` (`config/initializers/problem.rb`).
- Titles come from `config/locales/en.yml` under `problem_details.titles`.
- `ProblemType` values and URIs are append-only. Add a type only when a client will branch on it.

## Authentication and authorisation

`Api::ApplicationController` authenticates every call, then authorises it by the action of its RPC.

- `Authenticatable` (`app/controllers/concerns/authenticatable.rb`) sets `Current.actor` from the browser session first, then from an `Authorization: Bearer` token: a himari access token (`at+jwt`) for a client in `config.x.authn.himari_client_ids`, a GitHub Actions ID token, or an `sts:GetWebIdentityToken` token from an issuer in `config.x.authn.aws_issuers`. GitHub and AWS tokens must carry the audience `https://aid.rubykaigi.net`. A call without credentials stays anonymous; refused credentials answer `unauthenticated`.
- People's roles come from himari's `roles` claim. Machine roles come from `config.x.authn.machine_roles`, keyed by issuer and exact subject, extended without a deploy through the `NET_AID_MACHINE_ROLES` JSON.
- `Authorizable` derives the action `netaid:<Method>` from the routed RPC and asks `Authz::Policy.permit?`. An anonymous caller is answered `unauthenticated`, a caller without a role allowing it `permission_denied`. Controllers declare nothing.
- Role statements live in `app/models/authz/policy.rb`. An admin-only RPC is added to the operator's deny list. `spec/proto/rpc_actions_spec.rb` fails when some routed RPC is allowed for no role, or when two services declare the same method name.
- Check a further action inside an RPC with `authorize!("netaid:RestoreMutation", episode:)`.
- In a controller, read the caller with `current_actor`, which raises when there is none, or `current_actor_maybe`, and the browser session with `current_browser_session_maybe`. Outside a controller (models, jobs), use `Current.actor` and `Current.actor_maybe`.

Specs mint tokens with `spec/support/authn_helper.rb` (`himari_access_token`, `github_actions_token`, `aws_token`) after `stub_trusted_jwks`, and sign a browser in with `sign_in_as(roles:)`. WebMock blocks every other network call.

### Browser sessions

People sign in through himari in the browser. The session lives in the encrypted `__Host-Http-netaid-sess` cookie (`Secure`, `HttpOnly`, `SameSite=Lax`), holding the Actor, its roles and the himari access and refresh tokens as a `rubykaigi.net_aid.server.BrowserSession` message (`Authn::BrowserSession`).

| Path | What |
|---|---|
| `GET /auth/himari?return_to=<path>` | a page that POSTs, with a CSRF token, to OmniAuth's request phase; `return_to` must be a path on this origin |
| `GET /auth/himari/callback` | stores the session and redirects to `return_to` |
| `POST /auth/sign_out` | clears the session |
| `GET /auth/developer` | development and test only: signs in as any subject with any roles, for an hour |

- An RPC whose session has an expired access token answers `session-expired` without refreshing it. The frontend then calls `ViewerService.RefreshSession` once and retries; it is the only RPC that rewrites the session, so concurrent RPCs never race on a rotated refresh token.
- A refresh himari refuses clears the session and answers `session-revoked`.
- The session cookie expires 14 days after it was last written, matching himari's refresh-token cap.
- Request specs that use the session cookie must run over https (`https!`), as the cookie is `Secure`. `sign_in_as` does this.

### himari configuration

The himari clients are configured in `rubykaigi-net/tf/himari/config.ru`, outside this repository:

- `net-aid` (confidential, redirect `https://aid.rubykaigi.net/auth/himari/callback`), `net-aid-local` (confidential, redirect `http://localhost:3000/auth/himari/callback`, PKCE) and `net-aid-cli` (public, loopback redirects, PKCE).
- An AuthorizationRule for the three: `mint_jwt_access_token = true`, access tokens of 1 hour and refresh tokens of 14 days, and a `roles` claim from GitHub teams (`ruby-no-kai/rk-noc` admin, `kaigionrails/infra` operator, `ruby-no-kai/rk-orgz` and `ruby-no-kai/rkNN-orgz` viewer).
- The Actor is read from the access token, never the ID token, so the access token must carry `name` and `roles`.

The backend reads the `net-aid` client secret from `NET_AID_HIMARI_CLIENT_SECRET` (`net-aid-local`'s in development).

## Browser protection

`ConnectForgeryProtection` refuses POSTs without `Connect-Protocol-Version: 1` and requests whose `Sec-Fetch-Site` or `Origin` names another site, so no CSRF token is needed. Never grant CORS preflights for the API. CloudFront in front of the backend must forward `Connect-Protocol-Version`, `Connect-Timeout-Ms`, `Sec-Fetch-Site` and `Origin`.

## Testing

Request specs call RPCs the way a client does, through `spec/support/connect_helper.rb`:

```ruby
rpc = connect_method("ViewerService", "GetViewer")
expect(connect_call(rpc, Rk::NetAid::ViewerServiceGetViewerRequest.new)).to eq(expected)
connect_call(rpc, request, via: :get)        # GET
connect_call(rpc, request, codec: :proto)    # binary POST
```

- `connect_call` returns the response message, or a `ConnectHelper::ConnectError` with decoded details.
- Assert errors by problem type (`problem_type_of(error)`) and violations (`violations_of(error)` as `[field, reason]`).
- For a GET-able RPC, check that GET and binary POST answer the same as JSON POST.
- Tag a spec `:escaping_exceptions` to exercise the exceptions app.
