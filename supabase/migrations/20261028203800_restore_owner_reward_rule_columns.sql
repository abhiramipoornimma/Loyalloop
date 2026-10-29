begin;

alter table public.reward_rules
  add column if not exists minimum_purchase numeric(10,2)
    check (minimum_purchase is null or minimum_purchase >= 0);
alter table public.reward_rules
  add column if not exists validity_days integer
    check (validity_days is null or validity_days between 1 and 3650);
alter table public.reward_rules
  add column if not exists valid_until timestamptz;

grant select (minimum_purchase, validity_days, valid_until)
  on public.reward_rules to authenticated;

commit;
