create extension if not exists postgis;
create extension if not exists pgcrypto;

create table if not exists public.market_stores (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null,
  name_en text,
  phone text,
  whatsapp text,
  address text,
  city text not null default 'إب',
  location geography(point, 4326) not null,
  source text not null default 'merchant',
  source_ref text,
  is_verified boolean not null default false,
  is_active boolean not null default true,
  last_data_refresh timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.market_products (
  id uuid primary key default gen_random_uuid(),
  barcode text unique,
  name_ar text not null,
  name_en text,
  normalized_name text,
  brand text,
  category text,
  description_ar text,
  image_url text,
  image_license text,
  image_attribution text,
  source text not null default 'merchant',
  source_ref text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.market_offers (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.market_stores(id) on delete cascade,
  product_id uuid not null references public.market_products(id) on delete cascade,
  price numeric(12,2) not null check (price >= 0),
  currency text not null default 'YER',
  available boolean not null default true,
  quantity numeric(12,3),
  last_checked_at timestamptz not null default now(),
  source text not null default 'merchant',
  source_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, product_id)
);

create table if not exists public.market_price_history (
  id bigint generated always as identity primary key,
  offer_id uuid not null references public.market_offers(id) on delete cascade,
  price numeric(12,2) not null check (price >= 0),
  currency text not null default 'YER',
  available boolean not null default true,
  observed_at timestamptz not null default now(),
  source text not null default 'merchant'
);

create table if not exists public.merchant_store_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid not null references public.market_stores(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, store_id)
);

create table if not exists public.market_favorites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid references public.market_stores(id) on delete cascade,
  product_id uuid references public.market_products(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (
    (store_id is not null and product_id is null)
    or (store_id is null and product_id is not null)
  )
);

create unique index if not exists market_favorites_store_unique
  on public.market_favorites (user_id, store_id)
  where store_id is not null;

create unique index if not exists market_favorites_product_unique
  on public.market_favorites (user_id, product_id)
  where product_id is not null;

create index if not exists market_stores_location_gix
  on public.market_stores using gist (location);
create index if not exists market_products_normalized_name_idx
  on public.market_products (normalized_name);
create index if not exists market_products_category_idx
  on public.market_products (category);
create index if not exists market_offers_store_idx
  on public.market_offers (store_id);
create index if not exists market_offers_product_idx
  on public.market_offers (product_id);
create index if not exists market_offers_freshness_idx
  on public.market_offers (last_checked_at desc);

create or replace function public.search_market_products(
  p_lat double precision,
  p_lon double precision,
  p_radius_km double precision default 5,
  p_query text default null,
  p_category text default null
)
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
    st_distance(
      s.location,
      st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography
    ) / 1000.0
  from public.market_offers o
  join public.market_stores s on s.id = o.store_id
  join public.market_products p on p.id = o.product_id
  where s.is_active
    and p.is_active
    and st_dwithin(
      s.location,
      st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
      greatest(0.1, least(p_radius_km, 100)) * 1000
    )
    and (
      p_query is null or p_query = ''
      or p.name_ar ilike '%' || p_query || '%'
      or coalesce(p.name_en, '') ilike '%' || p_query || '%'
      or coalesce(p.brand, '') ilike '%' || p_query || '%'
      or coalesce(p.barcode, '') = p_query
    )
    and (
      p_category is null or p_category = '' or p.category = p_category
    )
  order by distance_km asc, o.available desc, o.price asc;
$$;

alter table public.market_stores enable row level security;
alter table public.market_products enable row level security;
alter table public.market_offers enable row level security;
alter table public.market_price_history enable row level security;
alter table public.merchant_store_claims enable row level security;
alter table public.market_favorites enable row level security;

drop policy if exists market_stores_public_read on public.market_stores;
create policy market_stores_public_read
  on public.market_stores for select to anon, authenticated
  using (is_active);

drop policy if exists market_products_public_read on public.market_products;
create policy market_products_public_read
  on public.market_products for select to anon, authenticated
  using (is_active);

drop policy if exists market_offers_public_read on public.market_offers;
create policy market_offers_public_read
  on public.market_offers for select to anon, authenticated
  using (
    exists (
      select 1 from public.market_stores s
      where s.id = market_offers.store_id and s.is_active
    )
    and exists (
      select 1 from public.market_products p
      where p.id = market_offers.product_id and p.is_active
    )
  );

drop policy if exists merchant_claims_read_own on public.merchant_store_claims;
create policy merchant_claims_read_own
  on public.merchant_store_claims for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists merchant_claims_insert_own on public.merchant_store_claims;
create policy merchant_claims_insert_own
  on public.merchant_store_claims for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists favorites_read_own on public.market_favorites;
create policy favorites_read_own
  on public.market_favorites for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists favorites_insert_own on public.market_favorites;
create policy favorites_insert_own
  on public.market_favorites for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists favorites_delete_own on public.market_favorites;
create policy favorites_delete_own
  on public.market_favorites for delete to authenticated
  using ((select auth.uid()) = user_id);

grant usage on schema public to anon, authenticated;
grant select on public.market_stores, public.market_products, public.market_offers
  to anon, authenticated;
grant select, insert on public.merchant_store_claims to authenticated;
grant select, insert, delete on public.market_favorites to authenticated;
grant execute on function public.search_market_products(
  double precision, double precision, double precision, text, text
) to anon, authenticated;
