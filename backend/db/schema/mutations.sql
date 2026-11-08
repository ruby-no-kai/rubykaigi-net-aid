create table mutations (
    id uuid primary key,                   -- client-generated
    actor_issuer varchar(64) not null,
    actor_subject varchar(255) not null,
    actor_display_name varchar(255),
    actor_credential_id varchar(255),
    actor_user_agent varchar(255),
    rpc varchar(255) not null,             -- rubykaigi.net_aid.DeviceService/AssignFill
    payload jsonb not null,                -- protojson google.protobuf.Any of the request as sent
    base_seqs jsonb not null,              -- {"<branch uuid>": seq}, from the header's cursors
    client_time timestamp(6) with time zone,
    received_at timestamp(6) with time zone not null default now(),
    outcome varchar(32) not null,          -- Mutation.Outcome value name: OUTCOME_APPLIED, OUTCOME_REJECTED
    response jsonb,                        -- protojson google.protobuf.Any of the response, for replay
    error jsonb                            -- protojson protobufable.ProblemDetails, for rejections
);

create index idx_mutations_actor on mutations (actor_issuer, actor_subject, received_at);

grant all privileges on mutations to app_admin;
grant select, insert, update, delete on mutations to app_user;
