# Type checking

The backend is typechecked by [Sorbet](https://sorbet.org/) with inline RBS comments. Signatures live in `#:` comments that Ruby ignores; `sorbet-runtime` is not loaded, so nothing about the types runs in production.

New Ruby files under `backend/app/`, `backend/lib/` and `backend/config/` start at `# typed: strict`. Specs carry no sigil.

## Layout

| Path | What | Generated |
|---|---|---|
| `backend/sorbet/config` | Sorbet options | |
| `backend/sorbet/tapioca/config.yml` | tapioca output directories and exclusions | |
| `backend/sorbet/tapioca/require.rb` | entrypoints tapioca loads beyond `Bundler.require` | |
| `backend/sorbet/rbi/annotations/` | community annotations | `tapioca annotations` |
| `backend/sorbet/rbi/shims/` | hand-written RBIs for what tapioca cannot see | |
| `third_party/sorbet/rbi/gems/` | gem RBIs | `tapioca gem` |
| `third_party/sorbet/rbi/dsl/` | Rails and protobuf DSL RBIs | `tapioca dsl` |

## Commands

```sh
mise run typecheck    # bundle exec srb tc in backend/
mise run tapioca      # regenerate gem, annotation and DSL RBIs (slow, boots Rails)
mise run gen:rbi      # regenerate protobuf message RBIs only (part of mise run gen)
```

- Run `mise run typecheck` after every change.
- Run `bundle exec tapioca gem` after `Gemfile.lock` changes, and `bundle exec tapioca dsl` after adding a model, a column, an association or a route. Nothing detects stale RBIs automatically.
- `tapioca dsl` boots Rails against the local database; start it with `docker compose up -d --wait db`.
- Run everything through mise (`mise x --` or an activated shell): `mise.toml` sets `BUNDLE_FORCE_RUBY_PLATFORM=false`, without which `sorbet-static` cannot resolve.
- Never run `srb tc -a`; its autocorrect inserts `T.` forms that need `sorbet-runtime`.

## Writing types

```ruby
#: (String, expires_in: Integer, ?scopes: Array[String]) -> Token
def issue(subject, expires_in:, scopes: [])

#: (String, readonly: bool,
#|  ?tags: Array[String]) -> void
def record_event(name, readonly:, tags: [])

DEFAULT_TTL = 300 #: Integer

def initialize(order_id:)
  @order_id = order_id #: String
  @invoice = nil #: Invoice?
end
```

- Every method, constant and instance variable gets a type, private methods included. Declare every instance variable in `initialize`.
- Never write `sig` blocks, `T.let`, `T.must` or `T.cast` in `.rb` files. `.rbi` shims are the exception, where `sig` is the syntax.
- A concern that calls its host's methods declares the host above `module` with `# @requires_ancestor: ActiveRecord::Base`. In a `ClassMethods` body, the first line is `#: self as singleton(ActiveRecord::Base)`.
- Prefer a shim in `sorbet/rbi/shims/` over a cast when a gem defines methods tapioca cannot see.

### Nilable values

Never write `#: as !nil`. In order of preference:

1. Restructure so the nil never exists (`fetch`, returning a block's value, `else raise` in a `case`).
2. Bind a guarded call to a local, then guard the local.
3. Give the owner a raising reader: `current_user` raises, `current_user_maybe` returns nil.
4. `Must.because(value) { "the invariant that makes it present" }`.
5. `Must.expect(value)` only for non-optional `belongs_to` readers, which tapioca types as nilable.

`Must` lives in `backend/app/models/must.rb`.

### Union values

- Narrow with `Must.be_a(value, Klass)`, never `#: as Klass`.
- End a `case` over every member of a union with `else value #: absurd`.
- Use `untyped` only for values that really are heterogeneous, never to silence an error.

## Strictness

| Sigil | Reports |
|---|---|
| `ignore` | nothing; the file is not read |
| `false` | constant resolution and syntax only |
| `true` | type errors, but no signatures required |
| `strict` | every method, constant and instance variable must be typed |

Every file is at `strict` unless listed below.

## Known gaps

| File | Level | Reason |
|---|---|---|
| `config/initializers/dsql_monkey.rb` | `true` | Reads `@raw_connection`, an instance variable of the PostgreSQL adapter that a strict file cannot declare |
| `config/puma.rb` | `ignore` | Evaluated by Puma's configuration DSL |
| `config/ci.rb` | `ignore` | Evaluated by `ActiveSupport::ContinuousIntegration` |

Shims in `backend/sorbet/rbi/shims/`:

- `connect_rpc_rails.rbi`: the routes DSL is mixed into the mapper at boot, and `connect_service` blocks are evaluated by `MethodMapping`.
- `google-protobuf.rbi`: well-known types reopened after `tapioca gem` runs (`Any.pack`, `Timestamp#to_time`, `Value.from_ruby`).
- `protobufable.rbi`: `AlbaBinding` installs its class methods through Alba's `helper`.
- `time.rbi`: `Time.current` returns `ActiveSupport::TimeWithZone`.

Annotations for ActionMailer are ignored (`typed_overrides` in `sorbet/tapioca/config.yml`), because ActionMailer is not loaded.

## References

- <https://sorbet.org/docs/rbs-support>
- <https://sorbet.org/docs/gradual>
- <https://github.com/Shopify/spoom>
