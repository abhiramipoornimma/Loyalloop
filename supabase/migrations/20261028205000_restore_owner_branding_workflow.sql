begin;

create or replace function public.owner_save_business_branding(
  p_business_id uuid,
  p_display_name text,
  p_logo_path text,
  p_background_color text,
  p_primary_color text,
  p_secondary_color text,
  p_text_color text,
  p_theme_name text,
  p_welcome_message text,
  p_description text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
begin
  if auth.uid() is null
     or not loyalloop_private.has_business_role(p_business_id, 'owner') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if pg_catalog.char_length(pg_catalog.btrim(coalesce(p_display_name, ''))) not between 1 and 60
     or p_background_color !~ '^#[0-9A-Fa-f]{6}$'
     or p_primary_color !~ '^#[0-9A-Fa-f]{6}$'
     or p_secondary_color !~ '^#[0-9A-Fa-f]{6}$'
     or p_text_color !~ '^#[0-9A-Fa-f]{6}$'
     or pg_catalog.char_length(coalesce(p_theme_name, '')) > 60
     or pg_catalog.char_length(coalesce(p_welcome_message, '')) > 100
     or pg_catalog.char_length(coalesce(p_description, '')) > 180
     or (p_logo_path is not null and (
       p_logo_path !~ ('^' || p_business_id::text || '/[^/].*$')
       or p_logo_path ~ '(^|/)\.\.(/|$)'
     )) then
    raise exception 'Branding values are invalid.' using errcode = '22023';
  end if;

  update public.businesses
  set display_name = pg_catalog.btrim(p_display_name)
  where id = p_business_id;
  if not found then
    raise exception 'Business not found.' using errcode = 'P0002';
  end if;

  insert into public.business_branding (
    business_id, logo_path, background_color, primary_color, secondary_color,
    text_color, theme_name, welcome_message, description
  ) values (
    p_business_id, p_logo_path, p_background_color, p_primary_color, p_secondary_color,
    p_text_color, p_theme_name, nullif(pg_catalog.btrim(p_welcome_message), ''),
    nullif(pg_catalog.btrim(p_description), '')
  )
  on conflict (business_id) do update
  set logo_path = excluded.logo_path,
      background_color = excluded.background_color,
      primary_color = excluded.primary_color,
      secondary_color = excluded.secondary_color,
      text_color = excluded.text_color,
      theme_name = excluded.theme_name,
      welcome_message = excluded.welcome_message,
      description = excluded.description,
      updated_at = pg_catalog.now();
end;
$$;

revoke all on function public.owner_save_business_branding(
  uuid, text, text, text, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.owner_save_business_branding(
  uuid, text, text, text, text, text, text, text, text, text
) to authenticated;

commit;
