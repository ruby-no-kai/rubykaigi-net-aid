create table branches (
    id uuid primary key default gen_random_uuid(),
    dataset varchar(32) not null,          -- Branch.Dataset value name: DATASET_PLAN, DATASET_FLEET
    episode_id uuid,                       -- plan branches only
    scope_key varchar(64) not null,        -- the Episode's uuid for Plan branches, 'fleet' for Fleet branches
    name varchar(64) not null,             -- main, or a snapshot label
    parent_id uuid,
    forked_at_seq bigint,
    head_seq bigint not null default 0,    -- seq of the branch's latest ChangeSet
    is_frozen boolean not null default false, -- frozen would clash with Object#frozen? in Active Record
    state varchar(32) not null,            -- Branch.State value name: STATE_PREPARING, STATE_READY
    created_at timestamp(6) with time zone not null default now(),
    updated_at timestamp(6) with time zone not null default now()
);

create unique index idx_branches_scope_name on branches (scope_key, name);
create index idx_branches_parent on branches (parent_id);

grant all privileges on branches to app_admin;
grant select, insert, update, delete on branches to app_user;
