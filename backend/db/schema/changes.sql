create table changes (
    id uuid primary key default gen_random_uuid(),
    branch_id uuid not null,
    seq bigint not null,
    entity_type varchar(64) not null,      -- proto message name, e.g. rubykaigi.net_aid.Site
    entity_id uuid not null,
    entity_lineage uuid not null,
    ordinal integer not null,              -- order of first touch within the ChangeSet
    op varchar(16) not null,               -- Change.Op value name: OP_UPSERT, OP_DELETE
    data jsonb,                            -- protojson after-image; the before-image on delete
    changed_fields jsonb                   -- array of top-level proto field names; empty on create and delete
);

create index idx_changes_branch_seq on changes (branch_id, seq);
create index idx_changes_branch_entity on changes (branch_id, entity_id, seq);

grant all privileges on changes to app_admin;
-- Append-only: the app never updates or deletes the changelog.
grant select, insert on changes to app_user;
