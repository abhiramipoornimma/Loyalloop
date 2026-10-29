-- Direct admin onboarding provisions a business and its verified owner as one
-- transaction. Subscription rows are intentionally excluded until a billing
-- provider and subscription-state workflow are defined.

create function public.admin_create_business_with_owner(
  p_slug text,
  p_display_name text,
  p_category text,
  p_contact_email text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  normalized_slug text := pg_catalog.lower(pg_catalog.btrim(p_slug));
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(p_contact_email));
  owner_user_id uuid;
  new_business_id uuid;
begin
  if caller_id is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_slug is null
     or p_display_name is null
     or p_category is null
     or p_contact_email is null
     or normalized_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
     or pg_catalog.char_length(normalized_slug) > 80
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_display_name, ''))) not between 1 and 120
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_category, ''))) not between 1 and 80
     or pg_catalog.char_length(normalized_email) not between 3 and 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Business details are invalid.' using errcode = '22023';
  end if;

  select u.id into owner_user_id
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where pg_catalog.lower(u.email) = normalized_email
    and u.email_confirmed_at is not null
  limit 1;
  if owner_user_id is null then
    raise exception 'Owner email must match a confirmed Auth account with a LoyalLoop profile.'
      using errcode = 'P0001';
  end if;

  new_business_id := public.admin_create_business(
    normalized_slug,
    pg_catalog.btrim(p_display_name),
    pg_catalog.btrim(p_category),
    normalized_email,
    null
  );
  perform public.admin_approve_business(new_business_id, owner_user_id);
  return new_business_id;
end;
$$;

revoke all on function public.admin_create_business_with_owner(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_create_business_with_owner(text, text, text, text)
  to authenticated;
