# Logging

The backend logs through [rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger). Every request writes one canonical line, the ActionController `Completed` line, saying who made it, which RPC handled it, how it ended and what work it did. Every job execution's canonical line is its `Performed` line.

Paths below are relative to `backend/`.

| Piece | Where |
|---|---|
| `RequestLogContext`: request-scoped tags, counters and outcome | `app/models/request_log_context.rb` |
| `on_log` hook, `RequestLogTagger` middleware, notification subscribers | `config/initializers/semantic_logger.rb` |
| `handler` tag | `app/controllers/concerns/handler_log_taggable.rb` |
| Payload fields | `app/controllers/concerns/action_log_payloadable.rb` |
| Level and message of the `Completed` line | `lib/net_aid/action_controller_log_subscriber.rb` |

## Formats

| Environment | Output |
|---|---|
| production | JSON on STDOUT, one document per line |
| development | colour text in `log/development.log`, on STDOUT under `rails server`, on STDERR in `rails console` |
| test | colour text in `log/test.log` |

Set `RAILS_LOG_FORMAT=json` to write JSON in development and test.

## The canonical line

```json
{
  "level": "info",
  "name": "Api::Viewer::ViewersController",
  "message": "Completed 200 netaid:GetViewer",
  "named_tags": { "request_id": "…", "handler": "netaid:GetViewer" },
  "payload": { "status": 200, "ip": "…", "user_agent": "…", "connect_method": "rubykaigi.net_aid.ViewerService/GetViewer" }
}
```

- `Started` logs at debug; `Completed` is the one line per request.
- 5xx logs at error, everything else at info.
- The message is `Completed <status> <handler>`. A request routed to no RPC, such as `/up`, names its `controller#action` instead.

### Tags (`named_tags`)

Tags identify the request and apply to every line written after they are set, never retroactively.

| Tag | Value |
|---|---|
| `request_id` | `action_dispatch.request_id` |
| `handler` | the authorisation action of the routed RPC, `netaid:<Method>`; absent for a method the service does not declare |
| `actor_issuer`, `actor_subject`, `credential_id` | the authenticated Actor (`Authenticatable`), or the Actor the himari callback signs in; absent for an anonymous caller and on lines written before authentication |
| `episode` | the Episode slug of the Plan branch the request names (`Authorizable`); absent when it names none |

### Payload fields

| Field | Value |
|---|---|
| `status`, `duration`, `method`, `path`, `controller`, `action` | rails_semantic_logger's defaults |
| `params` | the request message, filtered by `filter_parameters` |
| `connect_method` | the routed RPC, `<package>.<Service>/<Method>` (connect_rpc_rails) |
| `ip`, `user_agent` | the request; the user agent truncated to 255 characters |
| `connect_code` | the Connect error code the controller rendered, problems included |
| `error_class` | the exception a `rescue_from` handled, or the unhandled one |
| `problem_type` | the problem's `type` without its URI prefix, such as `permission-denied` |
| `authn_failure` | a Symbol naming why the credentials were refused: `expired`, `bad_signature`, `wrong_audience`, `unknown_issuer`, `unknown_kid`, `id_token_as_bearer`, `session_expired`, `session_revoked` or `sign_in_failed`; or why they could not be checked: `jwks_unavailable`, `refresh_unavailable` |
| `authn_issuer` | the unverified `iss` of a refused bearer token |
| `authn_sign_in_error` | the error OmniAuth redirected to `/auth/failure` with, such as `invalid_credentials`; absent unless it is a plain identifier |
| `authn_unavailable_cause` | the exception or HTTP status behind `jwks_unavailable` or `refresh_unavailable` |
| `authz_denied_action` | the action the policy denied, such as `netaid:CreateSite` |
| `mutation_id` | the `mutation_id` of the request's `MutationHeader`, for a `Changelog.write` with one |
| `mutation_outcome` | `OUTCOME_APPLIED`, `OUTCOME_REJECTED`, `replayed` when a stored outcome was returned, `reused` when the `mutation_id` belongs to another request, or `failed` when the write raised and journalled nothing |

Error fields are absent when the request did not fail. Authentication and authorisation failures answer 4xx, so their lines stay at info. An unreachable issuer answers 503 and logs at error. A token never appears on the line, only the reason it was refused. An exception escaping the controller logs as status 500 with `error_class`; `ConnectExceptions` renders it after `Completed`, so it has no `connect_code`.

### Counters

Counters are payload fields counting the work a request did, present only when non-zero.

| Counter | Source |
|---|---|
| `jobs_enqueued` | `enqueue.active_job` notifications |
| `occ_retries` | OCC retries taken by `retryable_transaction` |
| `change_sets_written` | ChangeSets inserted by `Changelog.write` |
| `changes_written` | Changes inserted by `Changelog.write`, `insert_all!` included |

## Jobs

A job's canonical line is rails_semantic_logger's `Performed` line. `RequestLogContext.apply` merges the context's counters into it, and tags added during the job apply to it as to any other line. `ActorJob`, included in `ApplicationJob`, tags it with `actor_issuer`, `actor_subject` and `credential_id` of the Actor it runs as. The executor resets the context per job, so nothing leaks between jobs.

## Adding to the canonical line

Each spec that logs lists what it adds in a "Logging" subsection.

- Tags only identify the request's scope: who, which RPC, which Episode. Add one with `RequestLogContext.add_tags(...)` as soon as it is known.
- A value describing the request as a whole is a payload field, snake_case with an area prefix: `authn_failure`, `mutation_outcome`. An enumerated value is a Symbol (`connect_code: :permission_denied`). Fields read from the request belong in `ActionLogPayloadable`; fields describing an error are its `Errors::ApiError#log_fields`, merged when it is rescued or rendered; other fields known where the work happens go through `RequestLogContext.add_fields(...)`.
- A count is a counter, `RequestLogContext.increment(:name)`, named as a plural noun or `<thing>_<past verb>`: `occ_retries`, `changes_written`. Prefer incrementing from an `ActiveSupport::Notifications` subscriber in `config/initializers/semantic_logger.rb`; increment at the call site only when no event exists.
- Never add a separate log line for something the canonical line can carry.
- A gate that refuses a request without raising, such as the sign-out origin check, logs the refusal at warn with a Symbol `reason` in the payload.
- `filter_parameters` does not apply to fields added by code. Never log tokens, cookies or other secrets.

## Querying

CloudWatch Logs Insights reads the JSON fields directly:

```
fields @timestamp, message, named_tags.request_id, payload.problem_type
| filter named_tags.handler = "netaid:GetViewer" and payload.status >= 400
```

```
fields @timestamp, message, payload.error_class
| filter level = "error"
```

```
filter named_tags.request_id = "…"
| sort @timestamp asc
```

## Testing

- Spec context behaviour from a `type: :model` example group, so rspec-rails resets `CurrentAttributes` between examples. Run the `on_log` hook with `SemanticLogger::Logger.call_subscribers(log)`.
- Assert a tag on a line logged from a `process_action.action_controller` subscriber, which runs after the callback chain has unwound, as the `Completed` line does.
- Capture lines by stubbing a controller's or `ActiveJob::Base`'s `logger` with `SemanticLogger::Test::CaptureLogEvents`.
- Controller specs skip the middleware stack, so cover `request_id` in a request spec.
