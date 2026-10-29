create function public.enroll_customer_by_email(
  p_business_id uuid,
  p_customer_email text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  target_id uuid;
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_customer_email, '')));
begin
  if caller_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not loyalloop_private.has_business_permission(p_business_id, 'enroll_customers') then
    raise exception 'Not authorized to enroll customers for this business' using errcode = '42501';
  end if;
  if normalized_email = ''
     or pg_catalog.char_length(normalized_email) > 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Enter a valid customer email address' using errcode = '22023';
  end if;

  select u.id into target_id
  from auth.users u
  where pg_catalog.lower(u.email) = normalized_email;

  if target_id is null then
    raise exception 'No LoyalLoop account was found for this email. Ask the customer to register first.'
      using errcode = 'P0002';
  end if;

  return public.enroll_customer(p_business_id, target_id, p_idempotency_key);
end;
$$;

revoke all on function public.enroll_customer_by_email(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.enroll_customer_by_email(uuid, text, text)
  to authenticated;
