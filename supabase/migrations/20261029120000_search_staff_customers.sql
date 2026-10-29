create function public.search_business_customers(
  p_business_id uuid,
  p_query text default ''
)
returns table (
  id uuid,
  customer_user_id uuid,
  full_name text,
  phone text
)
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  normalized_query text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  query_digits text := pg_catalog.regexp_replace(coalesce(p_query, ''), '[^0-9]', '', 'g');
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not loyalloop_private.has_business_permission(p_business_id, 'view_customer_data') then
    raise exception 'Not authorized to view customers for this business' using errcode = '42501';
  end if;
  if pg_catalog.char_length(normalized_query) > 100 then
    raise exception 'Search query is too long' using errcode = '22023';
  end if;

  return query
  select clm.id, clm.customer_user_id, p.full_name, p.phone
  from public.customer_loyalty_memberships clm
  join public.profiles p on p.user_id = clm.customer_user_id
  join auth.users u on u.id = clm.customer_user_id
  where clm.business_id = p_business_id
    and clm.status = 'active'
    and (
      normalized_query = ''
      or pg_catalog.strpos(pg_catalog.lower(coalesce(p.full_name, '')), normalized_query) > 0
      or (
        query_digits <> ''
        and pg_catalog.strpos(
          pg_catalog.regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'),
          query_digits
        ) > 0
      )
      or pg_catalog.strpos(pg_catalog.lower(coalesce(u.email, '')), normalized_query) > 0
      or pg_catalog.strpos(clm.id::text, normalized_query) > 0
      or pg_catalog.strpos(clm.customer_user_id::text, normalized_query) > 0
    )
  order by p.full_name, clm.enrolled_at desc
  limit 100;
end;
$$;

revoke all on function public.search_business_customers(uuid, text)
  from public, anon, authenticated;
grant execute on function public.search_business_customers(uuid, text)
  to authenticated;
