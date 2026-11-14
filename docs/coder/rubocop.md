# RuboCop

The backend runs RuboCop with rubocop-shopify and the rails, rspec and factory_bot plugins (`backend/.rubocop.yml`). Run it with `bin/rubocop` in `backend/`.

## Project cops

The project's own cops live in `backend/rubocop/` and are listed under `require:` in `backend/.rubocop.yml`. Each guards a mistake that looks right at the call site and fails silently rather than in a spec.

| Cop | Bans | Use instead | Why |
|---|---|---|---|
| `Dsql/TransactionOccAwareness` | `transaction` and `with_lock` | `retryable_transaction` or `non_idempotent_transaction` (`DsqlTransactionable`) | DSQL fails a transaction that conflicts with a concurrent commit (`OC000`/`OC001`). A bare transaction neither retries nor states that it must not, so a conflict surfaces as a 500. See [database.md](database.md#transactions). |
| `NetAid/NetHttp` | `Net::HTTP` and `require "net/http"` | `HTTPX.with`, passing `Rails.configuration.x.http.user_agent` and timeouts | A request through `Net::HTTP` goes out without the app's User-Agent and waits out its 60-second default timeouts. Gems may still use `Net::HTTP` themselves. |

An offense is a design signal. `backend/.rubocop.yml` excludes only the code implementing what a cop guards, such as `DsqlTransactionable` for `Dsql/TransactionOccAwareness`. Anywhere else, disable a cop inline with its reason: `# rubocop:disable NetAid/NetHttp -- <reason>`.
