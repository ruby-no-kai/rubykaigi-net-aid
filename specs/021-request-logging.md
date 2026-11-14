# 021-request-logging

## Summary

One canonical log line per request and per job, saying who made it, which RPC handled it, how it ended and what work it did, after Stripe's canonical log lines. The backend moves to rails_semantic_logger with JSON output, and the ActionController `Completed` line becomes the canonical line: request-scoped tags from a `RequestLogContext` merge into every line, and outcome fields and counters land on the `Completed` payload.

This spec sets up the logging foundation. 001 and 002 add their own tags, fields and counters to it, and later specs add theirs the same way.

## Motivation

- Answering "who did this and why did it fail" today needs several lines joined by request id. `Completed` carries neither the caller nor the problem a request answered with.
- Problems are rendered by `Protobufable::Connect::ProblemRescuable` through `rescue_from`, so a 4xx never reaches `payload[:exception]`, and its `Completed` line says nothing about why.
- `ActiveSupport::TaggedLogging` writes text, and every request writes both `Started` and `Completed` at info. A 500 looks like a 200 in CloudWatch.
- Writes go through `Changelog.write` (002) with OCC retries, Mutation replays and multi-branch ChangeSets. Their cost and outcome belong on the line of the request that caused them.
- On Lambda (007) logs land in CloudWatch Logs, where one JSON line per request is easy to query with Logs Insights.

## Explanation

### The canonical line

```json
{
  "level": "info",
  "name": "Api::Site::SitesController",
  "message": "Completed 200 netaid:CreateSite",
  "named_tags": {
    "request_id": "…",
    "handler": "netaid:CreateSite",
    "actor_issuer": "himari",
    "actor_subject": "github_12345",
    "credential_id": "…"
  },
  "payload": {
    "status": 200,
    "duration": 41.2,
    "ip": "…",
    "user_agent": "…",
    "connect_method": "rubykaigi.net_aid.SiteService/CreateSite",
    "mutation_id": "…",
    "mutation_outcome": "OUTCOME_APPLIED",
    "occ_retries": 1,
    "changes_written": 3
  }
}
```

- `Started` logs at debug; `Completed` is the one line per request.
- The level follows the status: 5xx logs at error, everything else at info.
- The message names the status and the handler, e.g. `Completed 403 netaid:CreateSite`, or `controller#action` for a request routed to no RPC (`/up`, the unknown-method catch-all).
- Error fields (`connect_code`, `problem_type`, `error_class`) are omitted when absent, as counters are.
- rails_semantic_logger's own `rescue_from handled <class>` line stays beside it for a handled exception, carrying the exception's message and first backtrace frame, which the canonical line leaves out.

### Tags (`named_tags`)

Identify the request, and apply to every line written after they are known.

| Tag | Set by | Value |
|---|---|---|
| `request_id` | middleware | `action_dispatch.request_id` |
| `handler` | `prepend_before_action` in `Api::ApplicationController` | the authorisation action, `netaid:<Method>` (001) |
| `actor_issuer`, `actor_subject`, `credential_id` | authentication (001) | the Actor, once resolved |
| `episode` | authorisation (001) | the Episode slug of the request's Plan branch, when there is one; a tag so lines inside the action carry it too |

### Payload fields

Describe the request as a whole, on the `Completed` line only.

| Field | Source |
|---|---|
| `ip`, `user_agent` | the request |
| `params` | rails_semantic_logger's default, filtered by `filter_parameters`; for a Connect JSON request this is the request message |
| `connect_method` | connect_rpc_rails' default, the routed `<service>/<method>` |
| `connect_code` | the Connect error code a controller rendered, when any; recorded in `RequestLogContext.connect_code` by `ConnectRequestInfo#render_connect_error` |
| `problem_type` | the `type` identifier (`permission-denied`) of the problem the controller rendered, raised or not; recorded in `RequestLogContext.rendered_problem` by `ConnectRequestInfo#render_problem` |
| `error_class` | the exception handled by `rescue_from`, or the unhandled one |
| fields added by other specs | e.g. 001's `authn_failure`, 002's `mutation_outcome` |

### Counters

Count the work a request did, reported only when non-zero.

| Counter | Source |
|---|---|
| `jobs_enqueued` | `enqueue.active_job` notification, for a job that was enqueued (not aborted or failed) |
| counters added by other specs | e.g. 002's `occ_retries`, `changes_written` |

### Jobs

Each job execution's canonical line is rails_semantic_logger's own `Performed` line for the job.

- The job sets `Current.actor` from the Actor that started it (002) and adds the same Actor tags, so the line carries them.
- `RequestLogContext.apply` also merges the context's counters into the payload of that line, recognised as the job log subscriber's perform line.
- The executor resets the context per job, so counters never leak between jobs. A job performed inline (the `:inline` or test adapter's `perform_enqueued_jobs`) runs within the enqueuing request's context, so its counters and tags land on that request's line.

### Conventions for other specs

Each spec that logs adds a short "Logging" subsection listing what it puts on the canonical line, as 001 and 002 do.

- Tags only for identifiers of the request's scope (who, which RPC, which Episode). A value describing one event is a payload field.
- Payload fields are snake_case with an area prefix: `authn_failure`, `mutation_outcome`, `export_id`.
- Counters are plural nouns or `<thing>_<past verb>`, unprefixed when generic: `occ_retries`, `changes_written`, `scans_recorded`. They appear only when non-zero.
- Prefer counting from an `ActiveSupport::Notifications` event; increment at the call site only when there is none.
- Never add a separate log line for something the canonical line can carry. rails_semantic_logger's `rescue_from handled` line is kept for the exception message and backtrace frame.


### Querying

CloudWatch Logs Insights, against the JSON fields:

```
fields @timestamp, message, named_tags.actor_subject, payload.problem_type
| filter named_tags.handler = "netaid:CreateSite" and payload.status >= 400
```

## Drawbacks

- A new message format (`Completed 200 netaid:CreateSite`) differs from Rails' default; nothing depends on the old one yet.
- Tags apply only to lines written after they are set, so lines logged during authentication carry no actor.
- A dependency on rails_semantic_logger, whose subscriber is subclassed through a private method.

## Considered Alternatives

- `around_action` with `logger.tagged`: unwinds before `Completed` is logged, so the canonical line loses the tags.
- Lograge: replaces the `Completed` line with its own, but has no request-scoped context merged into other lines.
- Separate lines for authentication failures and denials: easy to write, but split one request's story across lines.

## Prior Art

- Stripe, [canonical log lines](https://stripe.com/blog/canonical-log-lines).
- The `sorah-guides:rails-canonical-log-line` pattern this spec follows.

## Security and Privacy Considerations

- Request messages are logged as `params`, filtered by `filter_parameters`. Credentials never travel in request messages (001), and the filter list covers token-like names.
- `filter_parameters` does not apply to payload fields added by code. Never add tokens, cookies or other secrets as fields.
- `actor_subject` and `ip` identify people. How long CloudWatch keeps them is decided with the log group in 007, outside this spec.
- `user_agent` is truncated to 255 characters, as on the Actor (001).

## Mission Scope

### Out of scope

- Metrics, tracing and alerting (007 or later).
- Log retention, set on the CloudWatch log group (007).
- Frontend logging.
- The fields specific to authentication and the changelog, which 001 and 002 define.

### Expected Outcomes

- Every request writes exactly one info or error line at completion, carrying its handler, actor, status and outcome.
- Every job execution's `Performed` line carries the starting Actor and the job's counters.
- A 5xx logs at error; a 4xx at info with its `problem_type`.

## Implementation Plan

- Gems: `rails_semantic_logger`. Appenders through `config.rails_semantic_logger.appenders`: JSON to STDOUT in production; a colour log file in development and test (plus STDOUT under `rails server` and STDERR in `rails console` in development), switched to JSON with `RAILS_LOG_FORMAT=json`.
- `config/environments/production.rb`: replace the `TaggedLogging` logger and `log_tags`; keep `config.silence_healthcheck_path`.
- `config/application.rb`: `config.rails_semantic_logger.started = false`, `config.autoload_lib`.
- `app/models/request_log_context.rb`: `RequestLogContext < ActiveSupport::CurrentAttributes` with `tags`, `counters`, `rescued_exception`, `rendered_problem`, `connect_code`, `add_tags`, `increment`, `apply(log)`, `log_payload`.
- `config/initializers/semantic_logger.rb`: `SemanticLogger.on_log { RequestLogContext.apply(it) }`; `RequestLogTagger` middleware after `ActionDispatch::RequestId`; subscribers for `rescue_from_callback.action_controller` and `enqueue.active_job`.
- `app/controllers/concerns/handler_log_taggable.rb`: sets `handler` from the routed RPC, before any other callback.
- `app/controllers/concerns/action_log_payloadable.rb`: `append_info_to_payload` with the fields above, included in `Api::ApplicationController`.
- `lib/net_aid/action_controller_log_subscriber.rb`: level by status, `error_class` from an unhandled exception, message `Completed <status> <handler>`; swapped in from `config.after_initialize`.
- Connect errors: `ConnectRequestInfo#render_connect_error` records `connect_code` in the context for every error a controller renders, problems included, and `#render_problem` records the problem, so one rendered without raising (`Errors::InvalidRecord` from `RecordInvalid`) still has its `problem_type`. An exception escaping the controller logs as status 500 with `error_class`; `ConnectExceptions` renders it after `Completed`, so it records nothing.
- Job line: `RequestLogContext.apply` merges counters into rails_semantic_logger's job perform line; jobs add Actor tags where they set `Current.actor` (002).
- `docs/coder/logging.md`: the fields and the query forms.
- Specs per piece, as in the skill's references: context, `on_log` hook, a tag surviving the callback chain, payload concern per outcome, subscriber level and message, middleware tags in a request spec.

## Current Status

Implementation complete. Implementors MUST keep this section updated as they work.

### Checklist

- [x] Add `rails_semantic_logger`; JSON in production, colour text elsewhere, `RAILS_LOG_FORMAT=json` override; `started = false`; `autoload_lib`
- [x] `RequestLogContext` and the `on_log` hook (tags on every line; counters on the job perform line)
- [x] `RequestLogTagger` middleware (`request_id`)
- [x] `HandlerLogTaggable` (`handler` = `netaid:<Method>`)
- [x] `ActionLogPayloadable` (`ip`, `user_agent`, `problem_type`, `error_class`, `connect_code`, counters)
- [x] `rescue_from_callback.action_controller` and `enqueue.active_job` subscribers
- [x] `NetAid::ActionControllerLogSubscriber` (level by status, message `Completed <status> <handler>`)
- [x] `ConnectRequestInfo#render_connect_error` records `connect_code`
- [x] `docs/coder/logging.md`: fields, conventions, Logs Insights queries
- [x] Specs per piece

### Updates

- 2026-11-08: Interview complete.
- 2026-11-08: Added rails_semantic_logger 5.2. Appenders are declared through `config.rails_semantic_logger.appenders` per environment, since 5.x deprecates `format=`: JSON to STDOUT in production, a colour log file in development and test (plus STDOUT under `rails server` and STDERR in `rails console` in development), with `RAILS_LOG_FORMAT=json` switching development and test to JSON. `autoload_lib` was already on. A shim declares `RSpec::Matchers::Composable` for semantic_logger's RSpec matchers.
- 2026-11-08: Added `RequestLogContext` (with a `connect_code` attribute beside `rescued_exception`), the `on_log` hook, `RequestLogTagger`, the `rescue_from_callback` and `enqueue.active_job` subscribers, `HandlerLogTaggable`, `ActionLogPayloadable` and `connect_code` recording in `ConnectRequestInfo`, with their specs.
  - The job Performed line is recognised by its payload's `event_name` of `perform.active_job`.
  - `HandlerLogTaggable#rpc_action_name_maybe` derives `netaid:<Method>` from the `connect_rpcs` entry of the routed action, for 001's authorisation to reuse. An action serving no RPC (connect_rpc_rails' `connect_unknown_method` catch-all) gets no `handler` tag.
  - Error fields (`connect_code`, `error_class`, `problem_type`) are omitted when absent rather than logged as null.
  - rails_semantic_logger swaps the ActiveJob subscriber only when `ActiveJob::Base` is loaded by its `after_initialize`, so without eager loading (development, local test) jobs logged Rails' text lines. The initializer swaps it from `on_load(:active_job)` when the upstream subscriber is still attached.
  - Only `enqueue.active_job` is counted, as specified. `enqueue_at.active_job` (`set(wait:)`) and `enqueue_all.active_job` (`perform_all_later`) are not counted in `jobs_enqueued`.
- 2026-11-08: Added `NetAid::ActionControllerLogSubscriber`, swapped in from `config.after_initialize`, and `docs/coder/logging.md`. The message takes the handler from `RequestLogContext`'s `handler` tag, so it always matches the tag, and names `controller#action` for a request routed to no RPC (`/up`, the unknown-method catch-all). A request spec asserts the whole Completed line of `GetViewer`.
- 2026-11-08: Implementation complete. Every deliverable has a spec. Open points:
  - rails_semantic_logger still writes its own info line for each `rescue_from_callback` (`rescue_from handled <class>`), beside the Completed line. It carries the exception message and first backtrace frame, which the Completed line does not.
  - SemanticLogger writes from a background appender thread. Whether Lambda (007) needs `SemanticLogger.sync!` so lines are not held across a frozen invocation is left to 007.
- 2026-11-14: After validation:
  - The `rescue_from handled` line is kept; the spec now says so.
  - `problem_type` comes from the problem a controller rendered, so `Errors::InvalidRecord`, rendered from a rescued `RecordInvalid` without being raised, is logged with `invalid-record`.
  - `jobs_enqueued` skips an enqueue that was aborted or failed.
  - The example line shows `connect_method` and omits absent error fields.
