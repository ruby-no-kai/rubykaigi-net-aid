# 001-authentication-and-roles

## Summary

Authenticates API callers and authorises them by role. People sign in through himari (`https://idp.rubykaigi.net`): the browser holds a cookie session, and agents and scripts present himari-issued JWT access tokens. Machines (GitHub Actions workflows, AWS IAM roles) present OIDC ID tokens from their platform, the AWS ones obtained with `sts:GetWebIdentityToken`. People's roles are assigned in himari and arrive in the `roles` claim.

The authenticated caller becomes the Actor that the changelog and Mutation journal record (002). `ViewerService.GetViewer` reports the caller and their roles to the frontend.

## Motivation

- The spreadsheets are shared with the NOC team through Google accounts. The app replaces them, so it needs its own notion of who may read and who may write.
- Every write lands in the changelog and Mutation journal (002) with an Actor. Without authentication there is no Actor, and the audit history the team relies on to restore lost updates is meaningless.
- Callers are not only people:
  - rubykaigi-net GitHub Actions workflows read exports and may trigger them (013).
  - Automation on AWS (Lambda, EC2 hosts at the venue) refreshes fields such as an asset's `system` and `license`.
  - Coding agents read and write through the API on behalf of a person.
- himari is already the team's identity provider, and role assignment for people belongs there, not in this app's database.
- Scanning at the venue happens on phones, often on a flaky network. A session has to outlive offline periods long enough for a scanner to upload later (006, 017).

## Explanation

### Caller kinds

| Kind | Credential | Verified as | Actor `issuer` | Actor `subject` |
|---|---|---|---|---|
| Person in the browser | session cookie, after himari sign-in | session holding a himari access and refresh token | `himari` | himari `sub` (`github_<uid>`) |
| Person or agent via API | `Authorization: Bearer <himari access token>` | RFC 9068 `at+jwt` from `https://idp.rubykaigi.net`, `aud` in the client allowlist | `himari` | himari `sub` |
| GitHub Actions | `Authorization: Bearer <GitHub OIDC ID token>` | `iss` `https://token.actions.githubusercontent.com` | `github-actions` | `sub` (`repo:<owner>/<repo>:ref:...`) |
| AWS STS | `Authorization: Bearer <JWT from sts:GetWebIdentityToken>` | an AWS outbound identity federation issuer listed in `config.x.authn.aws_issuers` | `aws-sts` | role ARN (`sub`) |
| Developer, development and test only | session cookie, after `/auth/developer` | the subject, name and roles the form took | `developer` | the form's subject |

- Each trusted token issuer is a class under `Authn::Issuers`: `Himari`, `GithubActions` and `AwsSts`.

- The app and API host is `https://aid.rubykaigi.net`. It is the audience that GitHub Actions and AWS tokens must carry. Asset labels keep printing `https://nwa.rubykaigi.org/<tag>`, which only redirects into the app (007, 014).
- himari access tokens carry `aud` = the himari client id that obtained them. The API accepts the ids in `config.x.authn.himari_client_ids`:
  - `net-aid`: the confidential web client used by the browser sign-in.
  - `net-aid-cli`: a public client (loopback redirect URIs and PKCE, like `amc-mairu`) for agents and scripts to obtain a person's token.
- A himari ID token is refused as a bearer: the header `typ` must be `at+jwt`.
- Machine identities are mapped by their exact `sub`, with no patterns and no other claims. GitHub's `sub` already pins the repository and the ref or environment (`repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master`).
- `sts:GetWebIdentityToken` issues tokens from a per-account issuer URL, so trusted AWS issuers are configured explicitly, initially the rubykaigi account's.

### Browser sign-in

1. The frontend calls `ViewerService.GetViewer`. A Viewer without `actor` sends the user to `/auth/himari?return_to=<path>`. `return_to` is kept in the session and used after the callback. Only a relative path starting with a single `/` is accepted; anything else lands on `/`. The page answered there POSTs, with a CSRF token, to OmniAuth's request phase, since OmniAuth 2 starts a sign-in only on a POST.
2. omniauth-himari runs the authorisation code flow with PKCE against himari, requesting `openid offline_access`.
3. The callback verifies the access token as a bearer token is verified (audience `net-aid`) and stores in the encrypted cookie session a `rubykaigi.net_aid.server.BrowserSession` message, Base64 under the key `authn_pb`: the Actor, the roles, the access token's expiry, the access token and the refresh token. A value that does not decode reads as signed out.
4. An RPC whose session has an expired access token never refreshes it. It answers `Errors::SessionExpired`.
5. The frontend then calls `ViewerService.RefreshSession` once, single-flight across concurrent callers in the tab, and retries the failed calls. `RefreshSession` uses the refresh token, and himari re-runs its rules, so role changes and removals take effect here. The session then holds the new tokens and roles.
6. A refresh that himari refuses (`invalid_grant`) answers `Authn::SessionRefresher::Revoked` and leaves the cookie as it is. The frontend calls `GetViewer`, and sends the person to sign in again if it still answers `SessionExpired`.
7. `POST /auth/sign_out` clears the session. It is POST only, and refuses a request whose `Sec-Fetch-Site` or `Origin` names another site.

- The cookie is written only when the session's contents change (`NetAid::SessionCookieStore`), so an RPC that only read the session never puts back a refresh token that a concurrent `RefreshSession` rotated. Every write carries the 14-day expiry.
- Two tabs refreshing at the same moment race on the refresh token. The loser's refresh fails, and as a failed refresh writes nothing, the winner's cookie stays and the loser's `GetViewer` finds the session renewed.
- When himari cannot be reached, or answers the refresh with anything but a grant or `invalid_grant`, `RefreshSession` answers `Authn::Issuer::IssuerUnavailable` (`unavailable`) and keeps the session.
- Lifetimes, set by the himari rule for `net-aid`: access token 1 hour, refresh token 14 days. The refresh token's lifetime is an absolute cap from sign-in, so a session lasts at most 14 days.
- A phone offline past the cap keeps its outbox (006). The person signs in again and the outbox uploads then.

### Roles

People's roles arrive in the himari `roles` claim, set by a himari AuthorizationRule for the `net-aid` and `net-aid-cli` clients from GitHub team membership:

| GitHub team | Role |
|---|---|
| `ruby-no-kai/rk-noc` | `admin` |
| `kaigionrails/infra` | `operator` |
| `ruby-no-kai/rk-orgz`, `ruby-no-kai/rkNN-orgz` | `viewer` |

Machine identities get roles from a mapping in this app: a reviewed base mapping in `config/initializers/authn.rb`, merged with additional entries from the `NET_AID_MACHINE_ROLES` environment variable (JSON, loaded from SSM in production), so a new workflow or role can be added without a deploy.

| Role | May |
|---|---|
| `viewer` | read every branch, download exports |
| `operator` | everything `viewer` may, plus write Plan and Fleet entities, scan, assign fills, import cables |
| `admin` | everything `operator` may, plus Episode lifecycle (fork, close, Fleet snapshot), sheet imports, restoring rejected or overwritten Mutations |
| `exporter` | machine role: read every branch and open rubykaigi-net export PRs (013) |

### Actions and policies

Authorisation is by action, in the style of AWS IAM. Every RPC is an action named after its method, and roles grant actions through policy statements. Controllers declare nothing: the action is derived from the routed RPC, and an RPC no statement allows is denied.

- Action name: `netaid:<Method>`, one prefix for the whole API as an AWS service has. `rubykaigi.net_aid.SiteService/CreateSite` is `netaid:CreateSite`; `rubykaigi.net_aid.SyncService/PullChanges` is `netaid:PullChanges`.
- RPC method names are therefore unique across all services and name their entity (`CreateCableOrder`, not `CreateOrder`). A spec walking the routes asserts uniqueness (004).
- A statement has an effect (`allow` or `deny`) and either action patterns or, as IAM's `NotAction`, `not_actions` patterns matching every other action. `*` matches any run of characters.
- As in IAM, the statements of all of an Actor's roles are evaluated together: an action is permitted when a statement allows it and none denies it. An explicit deny in any role wins.
- Role policies:

  | Role | Statements |
  |---|---|
  | `viewer` | allow `netaid:Get*`, `netaid:List*`, `netaid:Lookup*`, `netaid:Bootstrap`, `netaid:PullChanges`, `netaid:Download*` |
  | `operator` | allow everything except (`not_actions`) `netaid:CreateEpisode`, `netaid:UpdateEpisode`, `netaid:CloseEpisode`, `netaid:CreateFleetSnapshot`, `netaid:CreateImport`, `netaid:ApplyImport`, `netaid:Restore*` |
  | `admin` | allow `netaid:*` |
  | `exporter` | viewer's, plus allow `netaid:CreateExport` |

- The operator's `not_actions` name the admin-only RPCs of 003 and 012 (Episode and branch lifecycle, sheet imports) and every restore. Cable imports (`netaid:ImportCables`, 019) stay allowed. A later spec that adds an admin-only RPC adds it to this list. The operator allows with `not_actions` rather than denying them, because an explicit deny wins: a deny in the operator role would take them from an Actor who is both admin and operator (in `ruby-no-kai/rk-noc` and `kaigionrails/infra`).
- `netaid:GetViewer` and `netaid:RefreshSession` are allowed for everyone, signed in or not.
- A caller with no recognised role is authenticated but denied every other action (`permission_denied`).
- Roles are global for now. Per-Episode scoping (e.g. Kaigi on Rails staff writing only `rk26kor`) is expected later. A statement will then gain an optional list of Episodes, and the policy check already receives the Episode a request targets, so controllers do not change.

### ViewerService

The messages are in `proto/rubykaigi/net_aid/viewer.proto`, the service in `viewer_service.proto`.

```proto
message Viewer {
  Actor actor = 1; // unset for an anonymous caller
  repeated string roles = 2;
}

// The caller recorded by the changelog.
message Actor {
  string issuer = 1; // himari, github-actions, aws-sts, or developer in development
  string subject = 2;
  string display_name = 3;
  string credential_id = 4; // the sign-in or token that authenticated the request
  string user_agent = 5; // the request's User-Agent, truncated to 255 characters
}

service ViewerService {
  rpc GetViewer(ViewerServiceGetViewerRequest) returns (ViewerServiceGetViewerResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
  // Refreshes the session's himari tokens and roles. The only RPC that rewrites the session.
  rpc RefreshSession(ViewerServiceRefreshSessionRequest) returns (ViewerServiceRefreshSessionResponse);
}
```

`display_name` is for history views:

| Caller | `display_name` |
|---|---|
| Person (browser or `net-aid-cli`) | himari `name` (the GitHub login) |
| GitHub Actions | `<repository> <workflow> #<run_number>` |
| AWS STS | the role name, the last part of the ARN |

`credential_id` ties writes to one sign-in or one run:

| Caller | `credential_id` |
|---|---|
| Browser session | a UUID generated at sign-in and kept across refreshes (himari exposes no session id claim) |
| himari bearer token | `<client_id>/<jti>`, e.g. `net-aid-cli/…`, so history can show a write made through the CLI or an agent |
| GitHub Actions | `<run_id>/<run_attempt>` |
| AWS STS | the token's `jti` |

An agent acting with a person's token writes as that person. History tells it apart by the `net-aid-cli/` prefix of `credential_id` and by `user_agent`, which agents are expected to set to a recognisable value.

`GetViewer` stays `NO_SIDE_EFFECTS` and never fails for an anonymous caller.

### Inside the backend

- `Current.actor` (an `Actor` value object) is set by a `before_action` and read by `Changelog.write` (002).
- `Api::ApplicationController` authorises every RPC before its action runs: `Authz::Policy.permit?(Current.actor, "netaid:CreateSite", episode:)`. `episode:` is the Episode of the Plan branch the request names (its `BranchRef` or `MutationHeader`, 004), resolved by the `Authorizable` concern. It is nil for Fleet branches and branchless RPCs, and is ignored until per-Episode scoping exists.
- A controller can check a further action inside an RPC with `authorize!("netaid:RestoreMutation", episode:)`, for RPCs whose effect depends on the request.
- Failures answer problems, which the frontend dispatches on by `type`:

  | Problem type | When |
  |---|---|
  | `PROBLEM_TYPE_UNAUTHENTICATED` (`unauthenticated`, 401) | no credentials, or an invalid token |
  | `PROBLEM_TYPE_SESSION_EXPIRED` (`session-expired`, 401) | the session's access token has expired; call `RefreshSession` and retry |
  | `PROBLEM_TYPE_SESSION_REVOKED` (`session-revoked`, 401) | himari refused the refresh; sign in again |
  | `PROBLEM_TYPE_PERMISSION_DENIED` (`permission-denied`, 403) | the policy denies the action |
  | `PROBLEM_TYPE_UNAVAILABLE` (`unavailable`, 503) | an issuer's JWKS or himari's token endpoint cannot be reached; retry later |

- Each failure raises its own class, a subclass that renders as its parent's problem type, so `error_class` on the canonical line names it. An error raised by a model is itself the problem, never wrapped by the controller, and declares the canonical line's fields it adds through `Errors::ApiError#log_fields`:

  | Class | Problem type | When |
  |---|---|---|
  | `Errors::SignInRequired` | `unauthenticated` | an anonymous caller calls an RPC other than `GetViewer` and `RefreshSession` |
  | `Errors::SignInFailed` | `unauthenticated` | OmniAuth redirects to `/auth/failure` |
  | `Errors::MalformedAuthorization` | `unauthenticated` | the `Authorization` header carries no bearer token |
  | `Authn::BearerVerifier::Failure` | `unauthenticated` | a bearer token is refused for any reason but expiry |
  | `Authn::BearerVerifier::Expired` | `unauthenticated` | a bearer token is past its expiry |
  | `Errors::NoSessionToRefresh` | `unauthenticated` | `RefreshSession` without a session |
  | `Errors::SessionExpired` | `session-expired` | the session's access token has expired |
  | `Authn::SessionRefresher::Revoked` | `session-revoked` | himari refused the refresh |
  | `Errors::ActionDenied` | `permission-denied` | no statement allows the action, or one denies it |
  | `Authn::Issuer::IssuerUnavailable` | `unavailable` | the JWKS cache or `Authn::SessionRefresher` cannot reach an issuer |

- `Auth::SessionsController` includes `Problem::Rescuable` and renders a problem as its failure page with the problem's status: 401 for a refused access token or a failed sign-in, 503 when himari's JWKS cannot be fetched.

## Drawbacks

- Accepting three issuers means three sets of JWKS and claim conventions to keep correct.
- Machine roles live in app configuration rather than himari, splitting role assignment across two places.
- The cookie session holds himari tokens, so it grows to a few kilobytes and stays close to the 4 KB cookie limit.
- A session cannot be revoked server-side. Removing someone in himari takes effect at their next token refresh, at most one access-token lifetime later.

## Considered Alternatives

- Static API keys for machines: simpler, but they are long-lived secrets to rotate. GitHub and AWS already issue short-lived OIDC tokens.
- Assigning roles in this app's database: duplicates himari and needs its own admin UI.
- Exchanging every machine token for a himari token first (token exchange): keeps all roles in himari, but himari has no token exchange or client credentials grant.
- Frontend-held bearer tokens instead of a cookie session: no backend redirects, but tokens stored in the browser are easier to leak, and `ConnectForgeryProtection` already makes a cookie safe without a CSRF token.
- A sessions table in DSQL: allows server-side revocation, at the cost of a database read on every request. Revocation through himari refresh is enough.
- Accepting tokens from any himari client: a token minted for another app could then be replayed here.

## Prior Art

- himari (the team's OIDC provider), its refresh-token revalidation and RFC 9068 access tokens.
- The himari clients of amc and Grafana in `rubykaigi-net/tf/himari/config.ru`, which already derive a `roles` claim from GitHub teams.
- GitHub Actions OIDC (`id-token: write`) as used for AWS role assumption.
- AWS IAM outbound identity federation (`sts:GetWebIdentityToken`).
- sts-cat, which already trades GitHub and AWS identities for scoped GitHub tokens.

## Security and Privacy Considerations

- Verify signature, `iss`, `aud`, `exp`, `nbf` and `iat` on every bearer token. Reject `alg: none` and algorithms outside an allowlist (RS256, ES256).
- The algorithm comes from the JWK's type and curve: RSA is RS256, EC P-256 is ES256, and any other key is refused. A JWK's `alg`, optional in RFC 7517, must agree when present, as must the token's header. Only the public key reaches the jwt gem, which otherwise verifies a JWK with its own `alg`.
- JWKS are cached per issuer until a token names an unknown `kid`, which triggers one refetch. Refetches are rate-limited per issuer, and each issuer's fetch holds a lock of its own, so a slow issuer holds up only its own tokens. A failed fetch answers for its issuer for 10 seconds before the next attempt.
- Machine subjects match exactly, never by prefix or pattern: GitHub's `sub` pins repository and ref or environment, and an AWS `sub` is a full role ARN. Grant write roles to an `environment:` subject protected by GitHub environment rules rather than to a branch ref.
- The session cookie is `__Host-Http-netaid-sess`, `Secure`, `HttpOnly`, `SameSite=Lax`, and encrypted with the Rails secret key base. It holds himari tokens, so it is as sensitive as they are. The `__Host-Http-` prefix makes a browser that supports it refuse the cookie unless it is also `HttpOnly`, so script on the page cannot set one.
- Bearer tokens and cookies are filtered from logs (`filter_parameter_logging`, request header logging).
- The Actor's `display_name` is shown to every operator in history views. It holds a name the person chose in himari, nothing more.
- No CORS: the frontend is same-origin on `aid.rubykaigi.net`, and bearer callers are not browsers. `rack-cors` stays out, and `ConnectForgeryProtection` is unchanged.
- `return_to` accepts only same-origin relative paths, so sign-in cannot be used as an open redirect.
- `/auth/developer` exists only in development and test; it is not routed in production.
- Logging rides on the request's canonical line (021), with one exception for a gate that answers without raising:
  - tags, once authentication resolves the Actor: `actor_issuer`, `actor_subject`, `credential_id`; `episode` once authorisation resolves it
  - the sign-in callback sets the same tags for the Actor it signs in
  - on an authentication failure, payload `authn_failure` (`expired`, `bad_signature`, `wrong_audience`, `unknown_issuer`, `unknown_kid`, `id_token_as_bearer`, `session_expired`, `session_revoked`, `sign_in_failed`, each a Symbol) and `authn_issuer` (from the unverified `iss`); never the token
  - `/auth/failure` reports `sign_in_failed`, with OmniAuth's error as `authn_sign_in_error` when it is a plain identifier
  - when an issuer cannot be reached, `authn_failure` `jwks_unavailable` or `refresh_unavailable` and `authn_unavailable_cause` (the exception or HTTP status)
  - on a denial, payload `authz_denied_action`
  - a refused sign-out logs `Refused a cross-site sign-out` at warn, with `reason` `:cross_site` and the `fetch_site` and `origin` it refused; its canonical line is a plain 403
  - these answer 4xx, so the line stays at info, except an unreachable issuer's 503, which logs at error

## Mission Scope

### Out of scope

- A role management UI. People's roles are managed in himari.
- Per-entity or per-Episode access control, beyond keeping the policy entry point ready for it.
- The frontend sign-in screens beyond redirecting to himari (005).
- The himari configuration itself, which lives in rubykaigi-net. This spec lists what it must provide.

### Expected Outcomes

- Every RPC except `GetViewer` and `RefreshSession` requires an authenticated caller with a sufficient role.
- `Current.actor` is set for every authenticated request and recorded by the changelog.
- A GitHub Actions workflow in rubykaigi-net and an AWS IAM role can call the API without any static secret.
- An agent can call the API with a person's himari access token obtained through `net-aid-cli`.
- The frontend can tell whether it is signed in and which actions to offer.

## Implementation Plan

- Gems: `omniauth-himari` for the browser flow (with `omniauth-rails_csrf_protection`), `jwt` for bearer verification.
- `app/models/actor.rb`: `Data.define(:issuer, :subject, :display_name, :credential_id, :user_agent, :roles)`. `roles` is not recorded in the changelog.
- `config/initializers/cors.rb` is removed.
- `app/models/current.rb`: `ActiveSupport::CurrentAttributes` with `actor` (`actor` raises, `actor_maybe` returns nil).
- `app/models/authn/`:
  - `Authn::Issuer`: the base of one class per trusted issuer under `Authn::Issuers` (`Himari`, `GithubActions`, `AwsSts`), with JWKS URL, accepted audiences, and claim mapping to `Actor`.
  - `Authn::BearerVerifier`: picks the issuer by the unverified `iss`, verifies, returns an `Actor`.
  - `Authn::JwksCache`: each issuer's signing keys, with a per-issuer lock and a short-lived failure.
  - `Authn::MachineRoles`: maps machine subjects to roles.
  - `Authn::BrowserSession`: the session's Actor and himari tokens, read from and written to the cookie session as a `rubykaigi.net_aid.server.BrowserSession` message (`proto/rubykaigi/net_aid/server/browser_session.proto`).
  - `Authn::SessionRefresher`: refreshes the session's tokens with himari, called only by `RefreshSession`.
  - `Authn::Issuer::IssuerUnavailable`: an issuer's JWKS or token endpoint could not be reached.
- `config/initializers/http.rb`: `config.x.http.user_agent`, the User-Agent that `Authn::JwksCache` and `Authn::SessionRefresher` pass to `HTTPX.with` along with their timeouts. The `NetAid/NetHttp` cop keeps app code off `Net::HTTP`.
- `lib/net_aid/session_cookie_store.rb`: `NetAid::SessionCookieStore`, the encrypted cookie store, writing the `__Host-Http-netaid-sess` cookie only when the session's contents change.
- `app/controllers/concerns/authenticatable.rb`: `before_action :authenticate`, reading the session first, then `Authorization: Bearer`.
- `app/controllers/concerns/authorizable.rb`: `before_action :authorize_rpc!`, deriving the action from the routed RPC, and `authorize!` for further checks.
- `app/models/authz/policy.rb`: `Authz::Policy.permit?(actor, action, episode: nil)`, pooling the statements of all the Actor's roles; an action is permitted when one allows it and none denies it. `app/models/authz/statement.rb`: `Authz::Statement`, a plain class with `effect` (`:allow` or `:deny`) and either `actions` or `not_actions` (later `episodes`). Role statements are defined in code.
- `app/models/errors.rb`: `Errors::SessionExpired`, `Errors::Unavailable` and the specific classes in [Inside the backend](#inside-the-backend); `PROBLEM_TYPE_SESSION_EXPIRED`, `PROBLEM_TYPE_SESSION_REVOKED` and `PROBLEM_TYPE_UNAVAILABLE` in `problem.proto`.
- `app/controllers/auth/sessions_controller.rb`: `GET /auth/himari`, `/auth/himari/callback`, `/auth/failure`, `POST /auth/sign_out`; in development and test also `/auth/developer` (OmniAuth developer strategy: a form taking a subject, a name and roles). Needs the cookies and session middleware, which `ActionController::API` apps omit by default.
- Configuration, and the cookie session middleware, in `config/initializers/authn.rb` under `Rails.configuration.x.authn`, with per-environment values in the same file:

  ```ruby
  config.x.authn.session_lifetime = 14.days # the cookie's expire_after
  config.x.authn.himari_issuer = "https://idp.rubykaigi.net"
  config.x.authn.himari_client_ids = %w[net-aid net-aid-cli] # plus net-aid-local in development
  config.x.authn.session_client_id = "net-aid" # net-aid-local in development
  config.x.authn.session_client_secret = ENV.fetch("NET_AID_HIMARI_CLIENT_SECRET", nil) # required in production
  config.x.authn.developer_sign_in = false # true in development and test
  config.x.authn.audience = "https://aid.rubykaigi.net"
  config.x.authn.github_actions_issuer = "https://token.actions.githubusercontent.com"
  config.x.authn.aws_issuers = %w[https://...] # sts:GetWebIdentityToken issuer of the rubykaigi account
  # The test environment points the issuers and the audience at .invalid hosts.
  config.x.authn.machine_roles = Authn::MachineRoles.merge(
    {
      "github-actions" => {"repo:ruby-no-kai/rubykaigi-net:ref:refs/heads/master" => %w[exporter]},
      "aws-sts" => {"arn:aws:iam::...:role/..." => %w[operator]},
    },
    ENV["NET_AID_MACHINE_ROLES"], # same shape, as JSON; a subject in both gets the union of roles
  )
  ```

- `proto/rubykaigi/net_aid/viewer.proto`: add `Actor` and `roles`. `viewer_service.proto`: add `RefreshSession`. `problem.proto`: add `SESSION_EXPIRED`, `SESSION_REVOKED` and `UNAVAILABLE` next to the existing `UNAUTHENTICATED` and `PERMISSION_DENIED`. `server/browser_session.proto`: the `BrowserSession` message the cookie holds, reachable from no service.
- himari configuration to add in `rubykaigi-net/tf/himari/config.ru`:
  - clients `net-aid` (confidential, redirect `https://aid.rubykaigi.net/auth/himari/callback`), `net-aid-local` (confidential, redirect `http://localhost:3000/auth/himari/callback`, PKCE, like `amc-local`) and `net-aid-cli` (public, loopback redirects, PKCE)
  - an AuthorizationRule for the three clients: `mint_jwt_access_token = true`, lifetimes (access 1 hour, refresh 14 days), and `roles` from GitHub teams as in [Roles](#roles)
- Specs:
  - request specs per caller kind, with tokens signed by a test key and a stubbed JWKS; browser sessions through `/auth/developer` or a `sign_in_as(roles:)` helper
  - expired token, wrong audience, wrong issuer, ID token presented as bearer, unknown `kid`, no role
  - `RefreshSession`: success, `invalid_grant`, two tabs refreshing at once, himari unavailable; other RPCs answer `SessionExpired` without refreshing
  - JWKS keys outside the allowlist, keys without `alg`, and JWKS fetch failures
  - `Authz::Policy` unit specs per role against representative actions
  - a spec that walks every RPC the services in `proto/` declare and asserts it is routed to an action that implements it, and that its derived action is public or allowed for at least one role, so a typo in a pattern cannot silently lock an RPC out

## Current Status

Implementation complete in this repository. The himari clients and rule in rubykaigi-net remain. Implementors MUST keep this section updated as they work.

### Checklist

- [x] Add `omniauth-himari`, `omniauth-rails_csrf_protection` and `jwt`; enable the cookies and session middleware with the `__Host-Http-netaid-sess` encrypted cookie store (`NetAid::SessionCookieStore`)
- [x] Remove `config/initializers/cors.rb`
- [x] `proto/rubykaigi/net_aid/viewer.proto`: `Actor`, `Viewer.actor`, `Viewer.roles`, `RefreshSession`; regenerate
- [x] `problem.proto` and `app/models/errors.rb`: `SESSION_EXPIRED`, `SESSION_REVOKED`
- [x] `Actor`, `Current`
- [x] `Authn::Issuer`, `Authn::BearerVerifier` (himari `at+jwt`, GitHub Actions, AWS), JWKS cache refetched on unknown `kid`
- [x] `Authn::MachineRoles` with the `NET_AID_MACHINE_ROLES` merge
- [x] `Auth::SessionsController` (`/auth/himari`, callback with `return_to`, `/auth/sign_out`, development-only `/auth/developer`)
- [x] `Authn::SessionRefresher` and `ViewerService.RefreshSession`; `GetViewer` returning the Actor and roles
- [x] `Authenticatable` and `Authorizable` concerns in `Api::ApplicationController`
- [x] `Authz::Policy`, `Authz::Statement` and the role statements
- [x] Actor tags and `authn_failure`, `authn_issuer`, `authz_denied_action` payload fields on the canonical line (021)
- [x] Request and unit specs listed in the Implementation Plan, including the route-walking spec
- [ ] himari: `net-aid`, `net-aid-local`, `net-aid-cli` clients and their AuthorizationRule in `rubykaigi-net/tf/himari/config.ru`

### Updates

- 2026-11-08: Interview complete. Logging moved onto the canonical log line of 021.
- 2026-11-08: Added the `omniauth-himari`, `omniauth-rails_csrf_protection` and `jwt` gems (plus `webmock` for specs); the session middleware follows with the browser sign-in. `Actor`, `Current`, `Authn::Issuer` (subclasses `Himari`, `GithubActions`, `AwsSts`), `Authn::BearerVerifier`, `Authn::JwksCache` and `Authn::MachineRoles` are in.
  - `config.x.authn.machine_roles` is merged in a `config.after_initialize` block of `config/initializers/authn.rb`, since `Authn::MachineRoles` is autoloaded and not yet loadable while the application class body runs.
  - `config.x.authn.aws_issuers` is empty and the base `aws-sts` mapping has no entry: the rubykaigi account's `sts:GetWebIdentityToken` issuer URL and the role ARN to grant are not known here. Deferred until deploy: fill both in then, or add them through `NET_AID_MACHINE_ROLES` and an environment override.
  - JWKS URLs: himari `/public/jwks`, GitHub `/.well-known/jwks`, AWS `/.well-known/jwks.json` (the path AWS documents for outbound identity federation issuers). The cache refetches a JWKS at most once a minute per issuer.
  - Failure reasons outside the spec's list are folded into it: a malformed token, a disallowed algorithm and a missing required claim report `bad_signature`; a token not yet valid (`nbf`, future `iat`) reports `expired`. Open point: add dedicated values if the distinction matters.
  - The algorithm allowlist stays RS256 and ES256 as specified. `sts:GetWebIdentityToken` also offers ES384, which callers must not choose.
  - A himari access token's `credential_id` uses its `client_id` claim (RFC 9068), which equals `aud` for himari. `display_name` falls back to `sub` when the token has no `name` claim.
  - `Actor::USER_AGENT_LIMIT` replaces the constant `ActionLogPayloadable` held, so the Actor and the canonical line truncate alike.
- 2026-11-08: `Authz::Policy`, `Authz::Statement` and the role statements, `Authenticatable` (bearer tokens) and `Authorizable` in `Api::ApplicationController`, and `Viewer.actor`/`Viewer.roles` on `GetViewer` (through `Api::ViewerResource` and `Api::ActorResource`). Actor tags, `authn_failure`, `authn_issuer` and `authz_denied_action` are on the canonical line through a new `RequestLogContext.add_fields`; `docs/coder/logging.md` and `docs/coder/api.md` describe them.
  - `Authorizable` resolves no Episode yet, since no RPC carries a `BranchRef` or `MutationHeader`; `authorization_episode_maybe` returns nil until 004 adds them, and the `episode` tag is set when it returns one.
  - Authorisation runs before request validation, because connect_rpc_rails moves `validate_connect_message!` behind every callback declared above an RPC. An unauthorised caller learns nothing about what a valid request looks like. When `authorization_episode_maybe` starts reading a `BranchRef`, it reads an unvalidated message.
  - The route-walking spec (`spec/proto/rpc_actions_spec.rb`) also asserts that method names are unique across services.
- 2026-11-08: Browser sign-in. Cookies and the `__Host-Http-netaid-sess` cookie store are in the middleware stack, `config/initializers/cors.rb` is gone, and `Auth::SessionsController`, `Authn::BrowserSession`, `Authn::SessionRefresher`, `ViewerService.RefreshSession` and `PROBLEM_TYPE_SESSION_EXPIRED`/`PROBLEM_TYPE_SESSION_REVOKED` are in. `Authenticatable` reads the session before a bearer token. `docs/coder/api.md` describes the flow and what himari must provide.
  - `RefreshSession` is in `viewer_service.proto`, beside `GetViewer`, rather than `viewer.proto`, which holds the messages.
  - `Auth::SessionsController` inherits `ActionController::Base`, for the CSRF token and views. `GET /auth/himari` answers a page that POSTs to OmniAuth's request phase with the token, since OmniAuth 2 starts a sign-in only on a POST that omniauth-rails_csrf_protection checks. The page submits itself with an inline script and keeps a button for when scripts are off.
  - `/auth/sign_out` is POST only, guarded by `SameSite=Lax` and a `Sec-Fetch-Site`/`Origin` check instead of a CSRF token the frontend does not hold. Open point for 005: the frontend signs out with a form POST or a same-origin `fetch`.
  - The Actor and roles of a session come from verifying its himari access token (audience `net-aid`, or `net-aid-local` in development), the same as a bearer token, not from the ID token. So the himari rule must put `name` and `roles` in access tokens; listed in `docs/coder/api.md`.
  - The cookie gets `expire_after` (14 days) only on the writes, sign-in and `RefreshSession`. Setting it on the store would rewrite the cookie on every request that reads the session, which brings back the race on a rotated refresh token.
  - `RefreshSession` without a session answers `unauthenticated`. A developer session, a refresh whose new token names another subject, and an access token himari answers that fails verification all clear the session and answer `session-revoked`. A himari outage (any other non-2xx) is a 500 and keeps the session.
  - `/auth/developer` sessions have issuer `developer`, last an hour and cannot be refreshed.
  - `filter_parameters` also filters the callback's `code`. No request headers are logged.
  - The `rubykaigi-net/tf/himari/config.ru` item stays open: that file is in another repository. What it must contain is in this spec's Implementation Plan and in `docs/coder/api.md`.
- 2026-11-08: Implementation complete, except the himari configuration in rubykaigi-net. Open points, all recorded above: the AWS issuer and role ARN to trust, the `authn_failure` values for malformed and not-yet-valid tokens, the sign-out request shape for 005, and that the himari access token must carry `name` and `roles`.
- 2026-11-08: Review: statements of all roles are pooled and an explicit deny wins, as in IAM. The operator role allows through `not_actions` instead of denying, so an Actor who is also an admin keeps the admin-only actions. `Authz::Statement` gains `not_actions` and becomes a plain class, since Sorbet rejects a keyword `initialize` on a `Data.define`.
- 2026-11-08: Review: `Authenticatable` gains `current_actor`/`current_actor_maybe` and a memoised `current_browser_session_maybe`, used by `Authorizable` and `ViewersController`.
- 2026-11-08: Review: the cookie session holds a Base64 `rubykaigi.net_aid.server.BrowserSession` message (`proto/rubykaigi/net_aid/server/`, a package for server-only messages) instead of a hand-mapped hash with a format number. A session that does not decode reads as signed out. `Authn::Issuer` subclasses move to `Authn::Issuers`, and specs sign with the RFC 9500 test keys.
- 2026-11-08: Review: each known authentication and authorisation failure raises its own class, an empty subclass of `Errors::Unauthenticated` (`SignInRequired`, `MalformedAuthorization`, `BearerTokenRefused`, `BearerTokenExpired`, `NoSessionToRefresh`) or of `Errors::PermissionDenied` (`ActionDenied`), so the problem types on the wire are unchanged and `error_class` on the canonical line names the failure.
- 2026-11-08: Review: AWS callers are vouched for by STS, so the issuer is `Authn::Issuers::AwsSts` and the Actor issuer and machine-role key are `aws-sts`.
- 2026-11-14: Validation fixes.
  - `Authn::BearerVerifier` takes the algorithm from the JWK's type and curve (RSA RS256, EC P-256 ES256) and passes jwt only the public key. A JWKS key with `alg` ES384 had made the allowlist intersection empty, which jwt treats as no restriction, so its tokens were accepted; a JWK without `alg` made every token signed with it fail.
  - A JWKS that cannot be fetched, and a himari token endpoint that cannot be reached during `RefreshSession`, raise `Authn::IssuerUnavailable` and answer `Errors::IssuerUnavailable`, the new `PROBLEM_TYPE_UNAVAILABLE` (503, Connect `unavailable`), instead of a 500. The sign-in callback answers a 503 failure page. `authn_failure` is `jwks_unavailable` or `refresh_unavailable`, with `authn_unavailable_cause`. `Authn::JwksCache` keeps a failure for 10 seconds and locks per issuer.
  - The cookie session store rewrote the cookie on every request that read the session, without `expire_after` outside sign-in and `RefreshSession`. So the first RPC after signing in turned the cookie into a browser-session cookie, and an RPC reading the session during a refresh could put back the rotated refresh token. `NetAid::SessionCookieStore` writes only when the contents change, always with the 14-day `expire_after`.
  - A refused refresh leaves the cookie alone instead of clearing it, so the loser of two tabs refreshing at once no longer wipes the cookie the winner wrote. `SESSION_REVOKED` and `RefreshSession` document calling `GetViewer` before sending the person to sign in.
  - Production fails to boot without `NET_AID_HIMARI_CLIENT_SECRET`.
  - The sign-in callback tags its line with the Actor, and `/auth/failure` reports `authn_failure` `sign_in_failed` with `authn_sign_in_error`.
  - `spec/proto/rpc_actions_spec.rb` walks the services declared in `proto/` rather than the routes, which connect_rpc_rails draws for every declared RPC whether or not an action implements it.
  - This spec's body now describes the code as it stands: the `developer` issuer, `Authn::Issuers`, the `authn_pb` session message, POST-only sign-out, the full configuration, the error classes, and `RefreshSession` in `viewer_service.proto`.
- 2026-11-14: Review: errors raised by models are problems themselves. `Authn::BearerVerifier::Failure` and `::Expired` replace `Errors::BearerTokenRefused` and `::BearerTokenExpired`, `Authn::SessionRefresher::Revoked` replaces `Errors::SessionRevoked`, and `Authn::Issuer::IssuerUnavailable` replaces `Authn::IssuerUnavailable` and `Errors::IssuerUnavailable`. Each error declares its canonical line fields in `log_fields`, which `ActionLogPayloadable` merges. `Auth::SessionsController` renders problems through `Problem::Rescuable`. Outbound HTTP goes through HTTPX (`NetAid::Http`) with a User-Agent.
- 2026-11-14: Authentication configuration and the cookie session middleware moved from `config/application.rb` and `config/environments/*.rb` to `config/initializers/authn.rb`.
- 2026-11-14: Review fixes.
  - `authn_failure` values are Symbols, as are the `reason` of `Authn::BearerVerifier::Failure` and `Authn::Issuer::IssuerUnavailable`.
  - `Authn::JwksCache` rescues only what fetching and parsing a JWKS raise: HTTPX errors, the socket, TLS and HTTP/2 errors HTTPX hands back unwrapped, and JSON, jwt and OpenSSL parse errors. `Authn::SessionRefresher::Revoked` keeps the verifier's refusal as its cause rather than in its message.
  - `NetAid::Http` is gone: `Authn::JwksCache` and `Authn::SessionRefresher` call `HTTPX.with` themselves, with the User-Agent from `config.x.http.user_agent` (`config/initializers/http.rb`).
  - The test environment configures `.invalid` issuers and audience, which `AuthnHelper` reads, so specs carry no real hostnames.
  - A sign-out refused by the origin check logs a warn line naming the reason. The `rubocop:disable Rails/ApplicationController` on `Auth::SessionsController` gives its reason.
  - The project's RuboCop cops are documented in `docs/coder/rubocop.md`.
- 2026-11-14: The AWS issuer URL and role ARN to trust are deferred until deploy.
