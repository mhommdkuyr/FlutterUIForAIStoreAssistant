-- Merchant ownership, publishing, administration, and audit helpers.
-- Apply after 20261003_market_engine.sql.

alter table public.market_stores
  add column if not exists owner_user_id uuid references auth.users(id) on delete set null;

alter table public.market_products
  add column if not exists created_by uuid references auth.users(id) on delete set null;

alter table public.market_offers
  add column if not exists created_by uuid references auth.users(id) on delete set null;

create index if not exists market_stores_owner_idx
  on public.market_stores (owner_user_id);
create index if not exists market_products_created_by_idx
  on public.market_products (created_by);
create index if not exists market_offers_created_by_idx
  on public.market_offers (created_by);

create or replace function public.market_is_admin()
returns boolean
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    (auth.jwt()->'app_metadata'->>'role') = 'admin',
    false
  );
$$;

drop policy if exists market_stores_owner_insert on public.market_stores;
create policy market_stores_owner_insert
  on public.market_stores for insert to authenticated
  with check ((select auth.uid()) = owner_user_id);

drop policy if exists market_stores_owner_update on public.market_stores;
create policy market_stores_owner_update
  on public.market_stores for update to authenticated
  using (
    (select auth.uid()) = owner_user_id
    or (select public.market_is_admin())
  )
  with check (
    (select auth.uid()) = owner_user_id
    or (select public.market_is_admin())
  );

drop policy if exists market_stores_owner_delete on public.market_stores;
create policy market_stores_owner_delete
  on public.market_stores for delete to authenticated
  using (
    (select auth.uid()) = owner_user_id
    or (select public.market_is_admin())
  );

drop policy if exists market_products_owner_insert on public.market_products;
create policy market_products_owner_insert
  on public.market_products for insert to authenticated
  with check ((select auth.uid()) = created_by);

drop policy if exists market_products_owner_update on public.market_products;
create policy market_products_owner_update
  on public.market_products for update to authenticated
  using (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  )
  with check (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  );

drop policy if exists market_products_owner_delete on public.market_products;
create policy market_products_owner_delete
  on public.market_products for delete to authenticated
  using (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  );

drop policy if exists market_offers_owner_insert on public.market_offers;
create policy market_offers_owner_insert
  on public.market_offers for insert to authenticated
  with check (
    (select auth.uid()) = created_by
    and exists (
      select 1
      from public.market_stores s
      where s.id = market_offers.store_id
        and s.owner_user_id = (select auth.uid())
    )
  );

drop policy if exists market_offers_owner_update on public.market_offers;
create policy market_offers_owner_update
  on public.market_offers for update to authenticated
  using (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  )
  with check (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  );

drop policy if exists market_offers_owner_delete on public.market_offers;
create policy market_offers_owner_delete
  on public.market_offers for delete to authenticated
  using (
    (select auth.uid()) = created_by
    or (select public.market_is_admin())
  );

drop policy if exists market_price_history_owner_insert
  on public.market_price_history;
create policy market_price_history_owner_insert
  on public.market_price_history for insert to authenticated
  with check (
    exists (
      select 1
      from public.market_offers o
      where o.id = market_price_history.offer_id
        and o.created_by = (select auth.uid())
    )
  );

drop policy if exists merchant_claims_admin_read
  on public.merchant_store_claims;
create policy merchant_claims_admin_read
  on public.merchant_store_claims for select to authenticated
  using ((select public.market_is_admin()));

drop policy if exists merchant_claims_admin_update
  on public.merchant_store_claims;
create policy merchant_claims_admin_update
  on public.merchant_store_claims for update to authenticated
  using ((select public.market_is_admin()))
  with check ((select public.market_is_admin()));

create or replace function public.merchant_get_store()
returns table (
  id uuid,
  name_ar text,
  name_en text,
  phone text,
  whatsapp text,
  address text,
  city text,
  latitude double precision,
  longitude double precision,
  verified boolean,
  source text,
  last_data_refresh timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    s.id,
    s.name_ar,
    s.name_en,
    s.phone,
    s.whatsapp,
    s.address,
    s.city,
    st_y(s.location::geometry),
    st_x(s.location::geometry),
    s.is_verified,
    s.source,
    s.last_data_refresh
  from public.market_stores s
  where s.owner_user_id = (select auth.uid())
    and s.is_active
  order by s.created_at asc
  limit 1;
$$;

create or replace function public.merchant_create_or_update_store(
  p_store_id uuid default null,
  p_name_ar text default '',
  p_phone text default null,
  p_whatsapp text default null,
  p_address text default null,
  p_lat double precision default 13.9667,
  p_lon double precision default 44.1833
)
returns table (
  id uuid,
  name_ar text,
  name_en text,
  phone text,
  whatsapp text,
  address text,
  city text,
  latitude double precision,
  longitude double precision,
  verified boolean,
  source text,
  last_data_refresh timestamptz
)
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required';
  end if;

  if nullif(trim(p_name_ar), '') is null then
    raise exception 'store name is required';
  end if;

  if p_store_id is null then
    insert into public.market_stores (
      name_ar,
      phone,
      whatsapp,
      address,
      city,
      location,
      source,
      owner_user_id,
      last_data_refresh
    )
    values (
      trim(p_name_ar),
      nullif(trim(p_phone), ''),
      nullif(trim(p_whatsapp), ''),
      nullif(trim(p_address), ''),
      'إب',
      st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
      'merchant',
      (select auth.uid()),
      now()
    )
    returning market_stores.id into v_id;
  else
    update public.market_stores
    set
      name_ar = trim(p_name_ar),
      phone = nullif(trim(p_phone), ''),
      whatsapp = nullif(trim(p_whatsapp), ''),
      address = nullif(trim(p_address), ''),
      location = st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
      last_data_refresh = now(),
      updated_at = now()
    where id = p_store_id
      and owner_user_id = (select auth.uid())
      and is_active
    returning market_stores.id into v_id;

    if v_id is null then
      raise exception 'store not found or not owned by current user';
    end if;
  end if;

  return query
  select
    s.id,
    s.name_ar,
    s.name_en,
    s.phone,
    s.whatsapp,
    s.address,
    s.city,
    st_y(s.location::geometry),
    st_x(s.location::geometry),
    s.is_verified,
    s.source,
    s.last_data_refresh
  from public.market_stores s
  where s.id = v_id;
end;
$$;

create or replace function public.merchant_upsert_offer(
  p_store_id uuid,
  p_product_id uuid default null,
  p_name_ar text default '',
  p_name_en text default null,
  p_brand text default null,
  p_category text default null,
  p_barcode text default null,
  p_price numeric default 0,
  p_quantity numeric default null,
  p_available boolean default true
)
returns table (offer_id uuid)
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_product_id uuid;
  v_offer_id uuid;
  v_normalized text;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required';
  end if;

  if not exists (
    select 1
    from public.market_stores
    where id = p_store_id
      and owner_user_id = (select auth.uid())
      and is_active
  ) then
    raise exception 'store not found or not owned by current user';
  end if;

  if nullif(trim(p_name_ar), '') is null then
    raise exception 'product name is required';
  end if;

  if p_price < 0 then
    raise exception 'price must be non-negative';
  end if;

  if p_product_id is not null then
    select id into v_product_id
    from public.market_products
    where id = p_product_id and is_active;

    if v_product_id is null then
      raise exception 'product not found';
    end if;
  else
    v_normalized := regexp_replace(
      lower(trim(p_name_ar)),
      '\s+',
      ' ',
      'g'
    );

    if nullif(trim(p_barcode), '') is not null then
      select id into v_product_id
      from public.market_products
      where barcode = nullif(trim(p_barcode), '')
        and is_active
      limit 1;
    end if;

    if v_product_id is null then
      select id into v_product_id
      from public.market_products
      where normalized_name = v_normalized
        and is_active
      order by created_at asc
      limit 1;
    end if;

    if v_product_id is null then
      insert into public.market_products (
        barcode,
        name_ar,
        name_en,
        normalized_name,
        brand,
        category,
        source,
        created_by,
        updated_at
      )
      values (
        nullif(trim(p_barcode), ''),
        trim(p_name_ar),
        nullif(trim(p_name_en), ''),
        v_normalized,
        nullif(trim(p_brand), ''),
        nullif(trim(p_category), ''),
        'merchant',
        (select auth.uid()),
        now()
      )
      returning id into v_product_id;
    end if;
  end if;

  insert into public.market_offers (
    store_id,
    product_id,
    price,
    currency,
    available,
    quantity,
    last_checked_at,
    source,
    created_by,
    updated_at
  )
  values (
    p_store_id,
    v_product_id,
    p_price,
    'YER',
    p_available,
    p_quantity,
    now(),
    'merchant',
    (select auth.uid()),
    now()
  )
  on conflict (store_id, product_id)
  do update set
    price = excluded.price,
    currency = excluded.currency,
    available = excluded.available,
    quantity = excluded.quantity,
    last_checked_at = now(),
    source = 'merchant',
    created_by = (select auth.uid()),
    updated_at = now()
  returning market_offers.id into v_offer_id;

  insert into public.market_price_history (
    offer_id,
    price,
    currency,
    available,
    observed_at,
    source
  )
  values (
    v_offer_id,
    p_price,
    'YER',
    p_available,
    now(),
    'merchant'
  );

  update public.market_stores
  set last_data_refresh = now(),
      updated_at = now()
  where id = p_store_id;

  return query select v_offer_id;
end;
$$;

create or replace function public.merchant_get_catalog()
returns table (
  offer_id uuid,
  store_id uuid,
  store_name_ar text,
  store_name_en text,
  phone text,
  whatsapp text,
  address text,
  city text,
  latitude double precision,
  longitude double precision,
  verified boolean,
  product_id uuid,
  product_name_ar text,
  product_name_en text,
  brand text,
  category text,
  barcode text,
  description_ar text,
  image_url text,
  image_license text,
  image_attribution text,
  price numeric,
  currency text,
  available boolean,
  quantity numeric,
  last_checked_at timestamptz,
  distance_km double precision
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    o.id,
    s.id,
    s.name_ar,
    s.name_en,
    s.phone,
    s.whatsapp,
    s.address,
    s.city,
    st_y(s.location::geometry),
    st_x(s.location::geometry),
    s.is_verified,
    p.id,
    p.name_ar,
    p.name_en,
    p.brand,
    p.category,
    p.barcode,
    p.description_ar,
    p.image_url,
    p.image_license,
    p.image_attribution,
    o.price,
    o.currency,
    o.available,
    o.quantity,
    o.last_checked_at,
    0::double precision
  from public.market_offers o
  join public.market_stores s on s.id = o.store_id
  join public.market_products p on p.id = o.product_id
  where s.owner_user_id = (select auth.uid())
    and s.is_active
    and p.is_active
  order by p.name_ar asc;
$$;

create or replace function public.admin_market_stats()
returns table (
  active_stores bigint,
  active_products bigint,
  active_offers bigint,
  fresh_offers_7d bigint
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
begin
  if not (select public.market_is_admin()) then
    raise exception 'admin only';
  end if;

  return query
  select
    (select count(*) from public.market_stores where is_active),
    (select count(*) from public.market_products where is_active),
    (select count(*)
      from public.market_offers o
      join public.market_stores s
        on s.id = o.store_id and s.is_active
      join public.market_products p
        on p.id = o.product_id and p.is_active),
    (select count(*)
      from public.market_offers o
      join public.market_stores s
        on s.id = o.store_id and s.is_active
      join public.market_products p
        on p.id = o.product_id and p.is_active
      where o.last_checked_at >= now() - interval '7 days');
end;
$$;

create or replace function public.admin_pending_claims()
returns table (
  id uuid,
  user_id uuid,
  store_id uuid,
  store_name_ar text,
  status text,
  created_at timestamptz
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
begin
  if not (select public.market_is_admin()) then
    raise exception 'admin only';
  end if;

  return query
  select
    c.id,
    c.user_id,
    c.store_id,
    s.name_ar,
    c.status,
    c.created_at
  from public.merchant_store_claims c
  join public.market_stores s on s.id = c.store_id
  where c.status = 'pending'
  order by c.created_at asc;
end;
$$;

create or replace function public.admin_set_claim_status(
  p_claim_id uuid,
  p_status text
)
returns void
language plpgsql
security invoker
set search_path = public, extensions
as $$
begin
  if not (select public.market_is_admin()) then
    raise exception 'admin only';
  end if;

  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid status';
  end if;

  update public.merchant_store_claims
  set status = p_status,
      updated_at = now()
  where id = p_claim_id;
end;
$$;

grant execute on function public.market_is_admin() to authenticated;
grant execute on function public.merchant_get_store() to authenticated;
grant execute on function public.merchant_create_or_update_store(
  uuid,
  text,
  text,
  text,
  text,
  double precision,
  double precision
) to authenticated;
grant execute on function public.merchant_upsert_offer(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  boolean
) to authenticated;
grant execute on function public.merchant_get_catalog() to authenticated;
grant execute on function public.admin_market_stats() to authenticated;
grant execute on function public.admin_pending_claims() to authenticated;
grant execute on function public.admin_set_claim_status(uuid, text) to authenticated;
