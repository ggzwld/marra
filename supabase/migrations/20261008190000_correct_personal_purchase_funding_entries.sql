begin;

create or replace function public.post_books_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.post_books_journal_entry(
    new.organization_id,
    'expense',
    new.id,
    new.expense_date,
    'Expense: ' || new.description,
    '5000',
    case when new.purchase_source_type = 'hotel_purchase' and exists (
      select 1
        from public.books_personal_purchase_records purchase
        join public.books_personal_workspaces workspace on workspace.user_id = purchase.buyer_user_id
       where purchase.id = new.purchase_source_id
         and workspace.organization_id = new.organization_id
    ) then '3000' else '1000' end,
    new.amount + new.tax_amount,
    new.currency_code,
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.post_books_expense() from public, anon, authenticated;

do $$
declare
  purchase_row record;
  workspace_owner_id uuid;
begin
  for purchase_row in
    select purchase.personal_organization_id,
           purchase.expense_id,
           purchase.status,
           expense.description,
           expense.expense_date,
           expense.currency_code,
           expense.amount + expense.tax_amount as total_amount
      from public.books_personal_purchase_records purchase
      join public.books_expenses expense on expense.id = purchase.expense_id
     where purchase.personal_organization_id is not null
       and expense.purchase_source_type = 'hotel_purchase'
  loop
    select organization.owner_id into workspace_owner_id
      from public.books_organizations organization
     where organization.id = purchase_row.personal_organization_id;

    perform public.post_books_journal_entry(
      purchase_row.personal_organization_id,
      'personal_expense_funding',
      purchase_row.expense_id,
      purchase_row.expense_date,
      'Personal funding for purchase: ' || purchase_row.description,
      '1000',
      '3000',
      purchase_row.total_amount,
      purchase_row.currency_code,
      workspace_owner_id
    );

    if purchase_row.status = 'reversed' then
      perform public.post_books_journal_entry(
        purchase_row.personal_organization_id,
        'personal_refund_funding',
        purchase_row.expense_id,
        current_date,
        'Personal funding reversal for refunded purchase: ' || purchase_row.description,
        '3000',
        '1000',
        purchase_row.total_amount,
        purchase_row.currency_code,
        workspace_owner_id
      );
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
commit;
