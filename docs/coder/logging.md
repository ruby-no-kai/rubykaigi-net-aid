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

Error fields are absent when the request did not fail. An exception escaping the controller logs as status 500 with `error_class`; `ConnectExceptions` renders it after `Completed`, so it has no `connect_code`.

### Counters

Counters are payload fields counting the work a request did, present only when non-zero.

| Counter | Source |
|---|---|
| `jobs_enqueued` | `enqueue.active_job` notifications |

## Jobs

A job's canonical line is rails_semantic_logger's `Performed` line. `RequestLogContext.apply` merges the context's counters into it, and tags added during the job apply to it as to any other line. The executor resets the context per job, so nothing leaks between jobs.

## Adding to the canonical line

Each spec that logs lists what it adds in a "Logging" subsection.

- Tags only identify the request's scope: who, which RPC, which Episode. Add one with `RequestLogContext.add_tags(...)` as soon as it is known.
- A value describing the request as a whole is a payload field in `ActionLogPayloadable`, snake_case with an area prefix: `authn_failure`, `mutation_outcome`.
- A count is a counter, `RequestLogContext.increment(:name)`, named as a plural noun or `<thing>_<past verb>`: `occ_retries`, `changes_written`. Prefer incrementing from an `ActiveSupport::Notifications` subscriber in `config/initializers/semantic_logger.rb`; increment at the call site only when no event exists.
- Never add a separate log line for something the canonical line can carry.
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
