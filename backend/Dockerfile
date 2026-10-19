# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t netaid .
# docker run -d -p 80:3000 -e RAILS_MASTER_KEY=<value from config/master.key> --name netaid netaid

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# psqldef applies db/schema/*.sql in the pre-deploy step; keep the version in sync with mise.toml
RUN --mount=type=tmpfs,target=/tmp/psqldef \
    ( cd /tmp/psqldef && curl -SsfLO "https://github.com/sqldef/sqldef/releases/download/v3.11.23/psqldef_linux_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz" ) \
 && printf '%s\n' "b103c0a94dc12cb6112856427b9224b10f912415337efbef4969885b3a423d96  /tmp/psqldef/psqldef_linux_arm64.tar.gz" "c648d86a2f3d66aa6285626173409cba5f7cbb4b4e890ef1040a1330c87a1a2b  /tmp/psqldef/psqldef_linux_amd64.tar.gz" | sha256sum -c --strict --ignore-missing - \
 && tar xf /tmp/psqldef/psqldef_linux_*.tar.gz -C /usr/local/bin psqldef

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./
COPY gen/proto/ruby/net_aid-proto.gemspec ./gen/proto/ruby/

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Copy application code
COPY . .




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --from=build /usr/local/bin/psqldef /usr/local/bin/psqldef

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
