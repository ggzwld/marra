begin;

create or replace function public.process_personal_books_purchase_record(target_record_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  purchase_row public.books_personal_purchase_records%rowtype;
  target_personal_organization_id uuid;
  target_expense_id uuid;
begin
  select * into purchase_row
    from public.books_personal_purchase_records
   where id = target_record_id
   for update;
  if not found then raise exception 'Purchase record was not found'; end if;
  if purchase_row.status = 'posted' then return 'posted'; end if;
  if purchase_row.status = 'reversed' then return 'reversed'; end if;

  target_personal_organization_id := public.ensure_personal_books_workspace(purchase_row.buyer_user_id);
  if target_personal_organization_id is null then
    update public.books_personal_purchase_records
       set status = 'failed', error_message = 'Buyer does not have a registered account', updated_at = now()
     where id = target_record_id;
    return 'failed';
  end if;

  insert into public.books_expenses (
    organization_id, description, expense_date, currency_code, amount, tax_amount,
    payment_status, purchase_source_type, purchase_source_id
  ) values (
    target_personal_organization_id,
    purchase_row.description,
    purchase_row.purchase_date,
    purchase_row.currency_code,
    purchase_row.amount,
    0,
    'paid',
    'hotel_purchase',
    purchase_row.id
  )
  on conflict (organization_id, purchase_source_type, purchase_source_id)
    where purchase_source_type is not null and purchase_source_id is not null
    do nothing
  returning id into target_expense_id;

  if target_expense_id is null then
    select expense.id into target_expense_id
      from public.books_expenses expense
     where expense.organization_id = target_personal_organization_id
       and expense.purchase_source_type = 'hotel_purchase'
       and expense.purchase_source_id = purchase_row.id;
  end if;
  if target_expense_id is null then raise exception 'Personal Books expense was not created'; end if;

  update public.books_personal_purchase_records
     set personal_organization_id = target_personal_organization_id,
         expense_id = target_expense_id,
         status = 'posted', error_message = null, updated_at = now()
   where id = target_record_id;
  return 'posted';
exception when others then
  update public.books_personal_purchase_records
     set status = 'failed', error_message = left(sqlerrm, 2000), updated_at = now()
   where id = target_record_id;
  return 'failed';
end;
$$;
revoke all on function public.process_personal_books_purchase_record(uuid) from public, anon, authenticated;
grant execute on function public.process_personal_books_purchase_record(uuid) to service_role;

drop function if exists public.retry_my_personal_books_purchases();

create or replace function public.apply_hotel_loyalty_delta(
  target_organization_id uuid,
  target_user_id uuid,
  target_entry_type text,
  target_points_delta bigint,
  target_source_type text,
  target_source_id uuid,
  target_description text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  account_row public.hotel_loyalty_accounts%rowtype;
  entry_uuid uuid;
  applied_positive bigint;
  applied_negative bigint;
begin
  if target_points_delta = 0 or target_source_id is null then raise exception 'A valid hotel loyalty entry is required'; end if;
  select * into account_row
    from public.hotel_loyalty_accounts
   where organization_id = target_organization_id and user_id = target_user_id
   for update;
  if not found then
    perform public.hotel_loyalty_make_account(target_organization_id, target_user_id);
    select * into account_row
      from public.hotel_loyalty_accounts
     where organization_id = target_organization_id and user_id = target_user_id
     for update;
  end if;
  if target_points_delta > 0 and not account_row.is_enrolled then return null; end if;

  insert into public.hotel_loyalty_ledger_entries (
    organization_id, user_id, entry_type, points_delta, source_type, source_id, description
  ) values (
    target_organization_id, target_user_id, target_entry_type, target_points_delta,
    target_source_type, target_source_id, target_description
  )
  on conflict (organization_id, user_id, source_type, source_id, entry_type) do nothing
  returning id into entry_uuid;
  if entry_uuid is null then return null; end if;

  if target_points_delta > 0 then
    applied_negative := least(account_row.debt_points, target_points_delta);
    applied_positive := target_points_delta - applied_negative;
    update public.hotel_loyalty_accounts
       set available_points = available_points + applied_positive,
           debt_points = debt_points - applied_negative,
           lifetime_points_earned = lifetime_points_earned + target_points_delta,
           updated_at = now()
     where organization_id = target_organization_id and user_id = target_user_id;
  else
    applied_positive := least(account_row.available_points, abs(target_points_delta));
    applied_negative := abs(target_points_delta) - applied_positive;
    update public.hotel_loyalty_accounts
       set available_points = available_points - applied_positive,
           debt_points = debt_points + applied_negative,
           updated_at = now()
     where organization_id = target_organization_id and user_id = target_user_id;
  end if;

  perform public.post_hotel_loyalty_ledger_entry(entry_uuid);
  return entry_uuid;
end;
$$;
revoke all on function public.apply_hotel_loyalty_delta(uuid, uuid, text, bigint, text, uuid, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
