begin;

-- Forward-only owner/admin workflow updates. Apply after 20261026120000.

-- Keep approved applicants eligible for owner provisioning without creating a
-- business during application review. Existing approved rows retain their
-- linked business and eligible owner.
alter table public.business_applications
  add column approved_owner_user_id uuid references auth.users(id) on delete restrict;
update public.business_applications ba
set approved_owner_user_id = bm.user_id
from public.business_memberships bm
where ba.status = 'approved'
  and ba.business_id = bm.business_id
  and bm.role = 'owner'
  and bm.status = 'active'
  and ba.approved_owner_user_id is null;
do $$
begin
  if exists (select 1 from public.business_applications where status = 'approved' and approved_owner_user_id is null) then
    raise exception 'Cannot preserve approved application history: an approved application has no active owner membership.';
  end if;
end $$;
alter table public.business_applications drop constraint business_applications_review_state_check;
alter table public.business_applications add constraint business_applications_review_state_check check (
  (status = 'pending' and reviewed_at is null and reviewed_by is null and business_id is null and approved_owner_user_id is null)
  or (status = 'approved' and reviewed_at is not null and reviewed_by is not null and approved_owner_user_id is not null)
  or (status = 'rejected' and reviewed_at is not null and reviewed_by is not null and business_id is null and approved_owner_user_id is null)
);
create index business_applications_approved_owner_idx on public.business_applications (approved_owner_user_id) where status = 'approved' and business_id is null;

create or replace function public.review_business_application(p_application_id uuid, p_decision text)
returns uuid language plpgsql security definer set search_path = pg_catalog set row_security = off as $$
declare
  application_row public.business_applications%rowtype;
  matched_owner_id uuid;
begin
  if auth.uid() is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected.' using errcode = '22023';
  end if;
  select * into application_row from public.business_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found.' using errcode = 'P0002'; end if;
  if application_row.status <> 'pending' then raise exception 'This application has already been reviewed.' using errcode = '55000'; end if;

  if p_decision = 'rejected' then
    update public.business_applications set status='rejected', reviewed_at=pg_catalog.now(), reviewed_by=auth.uid()
    where id=application_row.id;
    insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
    values(auth.uid(),'business_application.rejected','business_application',application_row.id::text,pg_catalog.jsonb_build_object('status','rejected'));
    return application_row.id;
  end if;

  select p.user_id into matched_owner_id
  from auth.users u join public.profiles p on p.user_id=u.id
  where pg_catalog.lower(u.email)=pg_catalog.lower(application_row.business_email) and u.email_confirmed_at is not null
  limit 1;
  if matched_owner_id is null then
    raise exception 'The applicant must register and confirm a LoyalLoop account using the business email before approval.' using errcode='P0001';
  end if;
  update public.business_applications
  set status='approved', reviewed_at=pg_catalog.now(), reviewed_by=auth.uid(), approved_owner_user_id=matched_owner_id
  where id=application_row.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
  values(auth.uid(),'business_application.approved','business_application',application_row.id::text,
         pg_catalog.jsonb_build_object('status','approved','eligible_owner_user_id',matched_owner_id));
  return application_row.id;
end;
$$;
revoke all on function public.review_business_application(uuid,text) from public,anon,authenticated;
grant execute on function public.review_business_application(uuid,text) to authenticated;

-- Business creation is a separate admin action and consumes only an approved,
-- confirmed owner application. Provisioning occurs atomically through existing
-- administrator workflows; no subscription is fabricated.
create or replace function public.admin_create_business_with_owner(p_slug text,p_display_name text,p_category text,p_contact_email text)
returns uuid language plpgsql security definer set search_path = pg_catalog set row_security = off as $$
declare
  caller_id uuid := auth.uid();
  normalized_slug text := pg_catalog.lower(pg_catalog.btrim(p_slug));
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(p_contact_email));
  application_row public.business_applications%rowtype;
  new_business_id uuid;
begin
  if caller_id is null or not loyalloop_private.is_platform_admin() then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_slug is null or p_display_name is null or p_category is null or p_contact_email is null
     or normalized_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or pg_catalog.char_length(normalized_slug)>80
     or pg_catalog.char_length(pg_catalog.btrim(p_display_name)) not between 1 and 120
     or pg_catalog.char_length(pg_catalog.btrim(p_category)) not between 1 and 80
     or pg_catalog.char_length(normalized_email) not between 3 and 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Business details are invalid.' using errcode='22023';
  end if;
  select * into application_row from public.business_applications ba
  where ba.status='approved' and ba.business_id is null
    and ba.approved_owner_user_id is not null
    and pg_catalog.lower(ba.business_email)=normalized_email
  order by ba.reviewed_at desc, ba.submitted_at desc limit 1 for update;
  if not found then raise exception 'No approved application is available for this confirmed owner email.' using errcode='P0001'; end if;
  if not exists(select 1 from auth.users u join public.profiles p on p.user_id=u.id
    where u.id=application_row.approved_owner_user_id and pg_catalog.lower(u.email)=normalized_email and u.email_confirmed_at is not null) then
    raise exception 'The approved owner account is no longer confirmed for this email.' using errcode='P0001';
  end if;
  new_business_id := public.admin_create_business(normalized_slug,pg_catalog.btrim(p_display_name),pg_catalog.btrim(p_category),normalized_email,application_row.contact_phone);
  perform public.admin_approve_business(new_business_id,application_row.approved_owner_user_id);
  update public.business_applications set business_id=new_business_id where id=application_row.id and business_id is null;
  if not found then raise exception 'Application was already consumed.' using errcode='55000'; end if;
  insert into public.audit_logs(actor_user_id,business_id,action,target_type,target_id,metadata)
  values(caller_id,new_business_id,'business.created_from_application','business_application',application_row.id::text,
         pg_catalog.jsonb_build_object('application_id',application_row.id,'owner_user_id',application_row.approved_owner_user_id));
  return new_business_id;
end;
$$;
revoke all on function public.admin_create_business_with_owner(text,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_create_business_with_owner(text,text,text,text) to authenticated;

-- Business owner branding save validates ownership and updates display name and
-- branding atomically. The logo path remains constrained to that business.
create function public.owner_save_business_branding(
  p_business_id uuid,p_display_name text,p_logo_path text,p_background_color text,p_primary_color text,
  p_secondary_color text,p_text_color text,p_theme_name text,p_welcome_message text,p_description text
) returns void language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id,'owner') then raise exception 'Not authorized' using errcode='42501'; end if;
  if pg_catalog.char_length(pg_catalog.btrim(coalesce(p_display_name,''))) not between 1 and 60
    or p_background_color !~ '^#[0-9A-Fa-f]{6}$' or p_primary_color !~ '^#[0-9A-Fa-f]{6}$'
    or p_secondary_color !~ '^#[0-9A-Fa-f]{6}$' or p_text_color !~ '^#[0-9A-Fa-f]{6}$'
    or pg_catalog.char_length(coalesce(p_theme_name,''))>60
    or pg_catalog.char_length(coalesce(p_welcome_message,''))>100
    or pg_catalog.char_length(coalesce(p_description,''))>180
    or (p_logo_path is not null and (p_logo_path !~ ('^'||p_business_id::text||'/[^/].*$') or p_logo_path ~ '(^|/)\.\.(/|$)')) then
    raise exception 'Branding values are invalid.' using errcode='22023';
  end if;
  update public.businesses set display_name=pg_catalog.btrim(p_display_name) where id=p_business_id;
  if not found then raise exception 'Business not found.' using errcode='P0002'; end if;
  insert into public.business_branding(business_id,logo_path,background_color,primary_color,secondary_color,text_color,theme_name,welcome_message,description)
  values(p_business_id,p_logo_path,p_background_color,p_primary_color,p_secondary_color,p_text_color,p_theme_name,
         nullif(pg_catalog.btrim(p_welcome_message),''),nullif(pg_catalog.btrim(p_description),''))
  on conflict(business_id) do update set logo_path=excluded.logo_path,background_color=excluded.background_color,
    primary_color=excluded.primary_color,secondary_color=excluded.secondary_color,text_color=excluded.text_color,
    theme_name=excluded.theme_name,welcome_message=excluded.welcome_message,description=excluded.description,updated_at=pg_catalog.now();
end $$;
revoke all on function public.owner_save_business_branding(uuid,text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.owner_save_business_branding(uuid,text,text,text,text,text,text,text,text,text) to authenticated;

-- A validity duration means the reward rule offer expires N days after publish;
-- NULL means no expiry. Minimum purchase is stored as a qualifying threshold.
alter table public.reward_rules add column minimum_purchase numeric(10,2) check (minimum_purchase is null or minimum_purchase >= 0);
alter table public.reward_rules add column validity_days integer check (validity_days is null or validity_days between 1 and 3650);
alter table public.reward_rules add column valid_until timestamptz;

create function public.reward_rule_validity_guard() returns trigger
language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
begin
  if not exists(select 1 from public.reward_rules rr where rr.id=new.reward_rule_id and rr.valid_until is not null and rr.valid_until<=pg_catalog.now()) then
    return new;
  end if;
  raise exception 'This reward offer has expired.' using errcode='55000';
end $$;
create trigger reward_redemptions_valid_rule_before_insert before insert on public.reward_redemptions
for each row execute function public.reward_rule_validity_guard();
revoke all on function public.reward_rule_validity_guard() from public,anon,authenticated;

create function public.stamp_awards_valid_rule_guard() returns trigger
language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
begin
  if new.transaction_type='award' and exists(
    select 1 from public.customer_loyalty_memberships clm
    join public.reward_rules rr on rr.program_id=clm.program_id and rr.is_active
    where clm.business_id=new.business_id and clm.id=new.loyalty_membership_id
      and rr.valid_until is not null and rr.valid_until<=pg_catalog.now()
  ) then raise exception 'The active reward offer has expired; publish a current rule before awarding stamps.' using errcode='55000'; end if;
  return new;
end $$;
create trigger stamp_transactions_valid_rule_before_insert before insert on public.stamp_transactions
for each row execute function public.stamp_awards_valid_rule_guard();
revoke all on function public.stamp_awards_valid_rule_guard() from public,anon,authenticated;

drop policy reward_rules_public_active_read on public.reward_rules;
create policy reward_rules_public_active_read on public.reward_rules
  for select to anon, authenticated
  using (is_active and (valid_until is null or valid_until>pg_catalog.now()) and exists (
    select 1 from public.loyalty_programs lp
    where lp.id=program_id and lp.business_id=reward_rules.business_id
      and lp.status='active' and loyalloop_private.is_public_business(lp.business_id)
  ));
grant select (minimum_purchase,validity_days,valid_until) on public.reward_rules to anon;

create function public.publish_reward_rule_with_terms(
  p_business_id uuid,p_stamps_required integer,p_reward_name text,p_description text default null,
  p_reward_type text default 'free_item',p_discount_percent integer default null,
  p_minimum_purchase numeric default null,p_validity_days integer default null,p_program_active boolean default true
) returns uuid language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
declare program_row public.loyalty_programs%rowtype; next_version integer; new_rule_id uuid;
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id,'owner') then raise exception 'Not authorized to publish rewards' using errcode='42501'; end if;
  if not loyalloop_private.is_public_business(p_business_id) then raise exception 'Business must be approved and active to publish rules'; end if;
  if p_stamps_required not between 1 and 1000 or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_reward_name,''))) not between 1 and 120
    or pg_catalog.char_length(coalesce(p_description,''))>500 or p_reward_type not in ('free_item','discount','other')
    or (p_reward_type='discount' and (p_discount_percent is null or p_discount_percent not between 1 and 100))
    or (p_reward_type<>'discount' and p_discount_percent is not null)
    or (p_minimum_purchase is not null and p_minimum_purchase not between 0 and 99999999.99)
    or (p_validity_days is not null and p_validity_days not between 1 and 3650) then raise exception 'Invalid reward rule'; end if;
  select * into program_row from public.loyalty_programs where business_id=p_business_id for update;
  if not found then raise exception 'Loyalty program not found' using errcode='P0002'; end if;
  select coalesce(max(version),0)+1 into next_version from public.reward_rules where program_id=program_row.id;
  update public.reward_rules set is_active=false where program_id=program_row.id and is_active;
  insert into public.reward_rules(business_id,program_id,version,stamps_required,reward_name,description,reward_type,discount_percent,is_active,created_by,minimum_purchase,validity_days,valid_until)
  values(p_business_id,program_row.id,next_version,p_stamps_required,pg_catalog.btrim(p_reward_name),nullif(pg_catalog.btrim(p_description),''),p_reward_type,p_discount_percent,true,auth.uid(),p_minimum_purchase,p_validity_days,
    case when p_validity_days is null then null else pg_catalog.now()+p_validity_days*interval '1 day' end)
  returning id into new_rule_id;
  update public.loyalty_programs set status=case when p_program_active then 'active'::public.program_status else 'paused'::public.program_status end where id=program_row.id;
  insert into public.audit_logs(actor_user_id,business_id,action,target_type,target_id,metadata)
  values(auth.uid(),p_business_id,'reward_rule.published','reward_rule',new_rule_id::text,
    pg_catalog.jsonb_build_object('version',next_version,'minimum_purchase',p_minimum_purchase,'validity_days',p_validity_days,'program_active',p_program_active));
  return new_rule_id;
end $$;
revoke all on function public.publish_reward_rule_with_terms(uuid,integer,text,text,text,integer,numeric,integer,boolean) from public,anon,authenticated;
grant execute on function public.publish_reward_rule_with_terms(uuid,integer,text,text,text,integer,numeric,integer,boolean) to authenticated;

create function public.set_loyalty_program_status(p_business_id uuid,p_status text)
returns public.program_status language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
declare program_row public.loyalty_programs%rowtype; new_status public.program_status;
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id,'owner') then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_status is null or p_status not in ('active','paused') then raise exception 'Status must be active or paused.' using errcode='22023'; end if;
  select * into program_row from public.loyalty_programs where business_id=p_business_id for update;
  if not found then raise exception 'Loyalty program not found.' using errcode='P0002'; end if;
  if p_status='active' and not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business must be approved and active before activating its loyalty programme.' using errcode='55000';
  end if;
  if p_status='active' and not exists(select 1 from public.reward_rules rr where rr.program_id=program_row.id and rr.is_active and (rr.valid_until is null or rr.valid_until>pg_catalog.now())) then
    raise exception 'Publish a current reward rule before activating the programme.' using errcode='55000';
  end if;
  new_status:=p_status::public.program_status;
  update public.loyalty_programs set status=new_status where id=program_row.id;
  insert into public.audit_logs(actor_user_id,business_id,action,target_type,target_id,metadata)
  values(auth.uid(),p_business_id,'loyalty_program.status_changed','loyalty_program',program_row.id::text,pg_catalog.jsonb_build_object('status',new_status));
  return new_status;
end $$;
revoke all on function public.set_loyalty_program_status(uuid,text) from public,anon,authenticated;
grant execute on function public.set_loyalty_program_status(uuid,text) to authenticated;

-- The invitation Edge Function uses the service role only for Auth Admin API
-- calls. This narrow RPC performs membership creation and auditing atomically.
create function public.owner_add_invited_staff(p_business_id uuid,p_owner_user_id uuid,p_staff_user_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog set row_security=off as $$
declare membership_id uuid;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Not authorized' using errcode='42501'; end if;
  if not exists(select 1 from public.business_memberships bm where bm.business_id=p_business_id
    and bm.user_id=p_owner_user_id and bm.role='owner' and bm.status='active') then
    raise exception 'The requesting account is not an active owner of this business.' using errcode='42501';
  end if;
  if not exists(select 1 from public.businesses b join public.business_details bd on bd.business_id=b.id
    where b.id=p_business_id and b.status='active' and bd.approval_status='approved') then
    raise exception 'Business is not approved and active.' using errcode='55000';
  end if;
  insert into public.business_memberships(business_id,user_id,role,status,can_enroll_customers,can_award_stamps,can_redeem_rewards,created_by)
  values(p_business_id,p_staff_user_id,'staff','active',false,true,true,p_owner_user_id)
  returning id into membership_id;
  insert into public.audit_logs(actor_user_id,business_id,action,target_type,target_id,metadata)
  values(p_owner_user_id,p_business_id,'staff.invited','business_membership',membership_id::text,
    pg_catalog.jsonb_build_object('staff_user_id',p_staff_user_id,'role','staff'));
  return membership_id;
end $$;
revoke all on function public.owner_add_invited_staff(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.owner_add_invited_staff(uuid,uuid,uuid) to service_role;

commit;
