create table change_sets (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null,
    seq bigint not null,                   -- 1, 2, 3, ... per branch in commit order
    mutation_id uuid,                      -- null for server-originated writes
    actor_issuer varchar(64) not null,
    actor_subject varchar(255) not null,
    actor_display_name varchar(255),
    actor_credential_id varchar(255),
    actor_user_agent varchar(255),
    committed_at timestamp(6) with time zone not null default now()
);

create unique index idx_change_sets_branch_seq on change_sets (branch_id, seq);
create index idx_change_sets_mutation on change_sets (mutation_id);

grant all privileges on change_sets to app_admin;
grant select, insert, update, delete on change_sets to app_user;
