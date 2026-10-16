-- Finalize approved merchant claims by assigning the store to the claimant.

create or replace function public.admin_set_claim_status(
  p_claim_id uuid,
  p_status text
)
returns void
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
  v_store_id uuid;
begin
  if not (select public.market_is_admin()) then
    raise exception 'admin only';
  end if;

  if p_status not in ('approved', 'rejected') then
    raise exception 'invalid status';
  end if;

  select user_id, store_id
  into v_user_id, v_store_id
  from public.merchant_store_claims
  where id = p_claim_id;

  if v_user_id is null then
    raise exception 'claim not found';
  end if;

  update public.merchant_store_claims
  set status = p_status,
      updated_at = now()
  where id = p_claim_id;

  if p_status = 'approved' then
    update public.market_stores
    set owner_user_id = v_user_id,
        is_verified = true,
        last_data_refresh = now(),
        updated_at = now()
    where id = v_store_id;
  end if;
end;
$$;

grant execute on function public.admin_set_claim_status(uuid, text) to authenticated;
