-- Sprint 4 backend: Sales, line items, payments, balances, 7 reports, audit log search.
-- Run AFTER 01-schema.sql, 02-sprint1.sql, 03-sprint2.sql and 04-sprint3.sql, in Supabase SQL Editor. Safe to run again.

-- 0. Safety check: stop early, with a clear message, if an old table with the same name is in the way ----
do $$
declare t text;
begin
  foreach t in array array['customers', 'employees', 'products'] loop
    if to_regclass('public.' || t) is null or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'id') then
      raise exception 'Table public.% is missing. Run the earlier numbered SQL files first, in order.', t;
    end if;
  end loop;
  foreach t in array array['sales', 'sale_lines', 'payments'] loop
    if to_regclass('public.' || t) is not null and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'id') then
      raise exception 'Table public.% already exists but has no id column, so these scripts did not create it. Open Table Editor to check it. If you do not need it, drop it and run this file again.', t;
    end if;
  end loop;
end $$;

-- 1. Tables ----------------------------------------------------------------
create sequence if not exists public.sale_no_seq;
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  trans_no text not null unique default ('T-' || lpad(nextval('public.sale_no_seq')::text, 3, '0')),
  sale_date date not null,
  customer_id uuid not null references public.customers (id),
  employee_id uuid not null references public.employees (id),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  stamp_action text not null default 'CREATED', stamp_by text not null default 'system', stamp_at timestamptz not null default now()
);
create table if not exists public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  product_id uuid not null references public.products (id),
  qty integer not null check (qty > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),   -- copied from the price history on the sales date; never typed
  line_total numeric(14,2) generated always as (round(qty * unit_price, 2)) stored,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  stamp_action text not null default 'CREATED', stamp_by text not null default 'system', stamp_at timestamptz not null default now()
);
create sequence if not exists public.or_no_seq;
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  or_no text not null unique default ('OR-' || lpad(nextval('public.or_no_seq')::text, 3, '0')),
  pay_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  stamp_by text not null default 'system', stamp_at timestamptz not null default now()
);

-- 2. Row Level Security + views ---------------------------------------------
-- Payments are recorded with the Edit Sale right. Line items, payments and balances need View Sale Details.
alter table public.sales      enable row level security;
alter table public.sale_lines enable row level security;
alter table public.payments   enable row level security;
drop policy if exists "Read sales" on public.sales;
create policy "Read sales" on public.sales for select to authenticated using (public.has_access('sale.') and (status = 'ACTIVE' or public.is_staff()));
drop policy if exists "Read sale lines" on public.sale_lines;
create policy "Read sale lines" on public.sale_lines for select to authenticated using (public.has_right('sale.view') and (status = 'ACTIVE' or public.is_staff()));
drop policy if exists "Read payments" on public.payments;
create policy "Read payments" on public.payments for select to authenticated using (public.has_right('sale.view'));

-- These views include customer and employee names, so they run with owner rights and filter by right themselves.
create or replace view public.sales_view as
select s.id, s.trans_no, s.sale_date, s.customer_id, s.employee_id, s.status, s.stamp_action, s.stamp_by, s.stamp_at,
  c.cust_no, c.name as customer_name, e.emp_no, e.first_name || ' ' || e.last_name as employee_name,
  coalesce((select sum(l.line_total) from public.sale_lines l where l.sale_id = s.id and l.status = 'ACTIVE'), 0) as total,
  coalesce((select sum(p.amount) from public.payments p where p.sale_id = s.id), 0) as paid
from public.sales s join public.customers c on c.id = s.customer_id join public.employees e on e.id = s.employee_id
where public.has_access('sale.') and (s.status = 'ACTIVE' or public.is_staff());

create or replace view public.sale_lines_view as
select l.id, l.sale_id, l.product_id, l.qty, l.unit_price, l.line_total, l.status, l.stamp_action, l.stamp_by, l.stamp_at, p.prod_code, p.description
from public.sale_lines l join public.products p on p.id = l.product_id
where public.has_right('sale.view') and (l.status = 'ACTIVE' or public.is_staff());
revoke all on public.sales_view, public.sale_lines_view from anon;
grant select on public.sales_view, public.sale_lines_view to authenticated;

-- 3. Pick lists for the sale forms (people with sale rights may not hold customer or HR rights) --
create or replace function public.sale_customers() returns table (id uuid, cust_no text, name text)
language sql stable security definer set search_path = '' as $$
  select c.id, c.cust_no, c.name from public.customers c
  where c.status = 'ACTIVE' and (public.has_right('sale.add') or public.has_right('sale.edit')) order by c.cust_no
$$;
create or replace function public.sale_employees() returns table (id uuid, emp_no text, full_name text)
language sql stable security definer set search_path = '' as $$
  select e.id, e.emp_no, e.first_name || ' ' || e.last_name from public.employees e
  where e.status = 'ACTIVE' and (public.has_right('sale.add') or public.has_right('sale.edit')) order by e.emp_no
$$;
create or replace function public.sale_products() returns table (id uuid, prod_code text, description text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.prod_code, p.description from public.products p
  where p.status = 'ACTIVE' and (public.has_right('sale.line_add') or public.has_right('sale.line_edit')) order by p.prod_code
$$;

-- 4. Guard rules -------------------------------------------------------------
create or replace function public._check_not_overpaid(p_sale uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select coalesce(sum(amount), 0) from public.payments where sale_id = p_sale)
     > (select coalesce(sum(line_total), 0) from public.sale_lines where sale_id = p_sale and status = 'ACTIVE') then
    raise exception 'OVERPAY';
  end if;
end $$;

-- Customers, employees and products that appear on active sales cannot be deleted.
create or replace function public._block_delete_in_use() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'INACTIVE' and old.status = 'ACTIVE' then
    if tg_table_name = 'customers' and exists (select 1 from public.sales where customer_id = new.id and status = 'ACTIVE') then raise exception 'IN_USE'; end if;
    if tg_table_name = 'employees' and exists (select 1 from public.sales where employee_id = new.id and status = 'ACTIVE') then raise exception 'IN_USE'; end if;
    if tg_table_name = 'products' and exists (select 1 from public.sale_lines l join public.sales s on s.id = l.sale_id
        where l.product_id = new.id and l.status = 'ACTIVE' and s.status = 'ACTIVE') then raise exception 'IN_USE'; end if;
  end if;
  return new;
end $$;
drop trigger if exists block_delete_customers on public.customers;
create trigger block_delete_customers before update of status on public.customers for each row execute function public._block_delete_in_use();
drop trigger if exists block_delete_employees on public.employees;
create trigger block_delete_employees before update of status on public.employees for each row execute function public._block_delete_in_use();
drop trigger if exists block_delete_products on public.products;
create trigger block_delete_products before update of status on public.products for each row execute function public._block_delete_in_use();

-- 5. Actions ---------------------------------------------------------------------
create or replace function public.sale_save(p_id uuid, p_date date, p_customer uuid, p_employee uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if p_date is null
     or not exists (select 1 from public.customers where id = p_customer and status = 'ACTIVE')
     or not exists (select 1 from public.employees where id = p_employee and status = 'ACTIVE') then raise exception 'BAD_INPUT'; end if;
  if p_id is null then
    if not public.has_right('sale.add') then raise exception 'NOT_ALLOWED'; end if;
    insert into public.sales (sale_date, customer_id, employee_id, stamp_by) values (p_date, p_customer, p_employee, public._stamp_name()) returning id into v_id;
    perform public._audit('ADD_SALE', v_id);
  else
    if not public.has_right('sale.edit') then raise exception 'NOT_ALLOWED'; end if;
    update public.sales set sale_date = p_date, customer_id = p_customer, employee_id = p_employee,
      stamp_action = 'EDITED', stamp_by = public._stamp_name(), stamp_at = now() where id = p_id and status = 'ACTIVE';
    if not found then raise exception 'NOT_FOUND'; end if;
    perform public._audit('EDIT_SALE', p_id);
  end if;
  return v_id;
end $$;

create or replace function public.sale_set_deleted(p_id uuid, p_deleted boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_deleted and not public.has_right('sale.delete') then raise exception 'NOT_ALLOWED'; end if;
  if not p_deleted and not public.is_staff() then raise exception 'NOT_ALLOWED'; end if;
  update public.sales set status = case when p_deleted then 'INACTIVE' else 'ACTIVE' end,
    stamp_action = case when p_deleted then 'DELETED' else 'RESTORED' end, stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._audit(case when p_deleted then 'DELETE_SALE' else 'RESTORE_SALE' end, p_id);
end $$;

create or replace function public.line_save(p_id uuid, p_sale uuid, p_product uuid, p_qty integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id; v_sale uuid := p_sale; v_date date; v_price numeric;
begin
  if p_qty is null or p_qty < 1 then raise exception 'BAD_INPUT'; end if;
  if p_id is null then
    if not public.has_right('sale.line_add') then raise exception 'NOT_ALLOWED'; end if;
  else
    if not public.has_right('sale.line_edit') then raise exception 'NOT_ALLOWED'; end if;
    select sale_id into v_sale from public.sale_lines where id = p_id and status = 'ACTIVE';
    if v_sale is null then raise exception 'NOT_FOUND'; end if;
  end if;
  select sale_date into v_date from public.sales where id = v_sale and status = 'ACTIVE';
  if v_date is null or not exists (select 1 from public.products where id = p_product and status = 'ACTIVE') then raise exception 'NOT_FOUND'; end if;
  -- The unit price is the price in force on the sales date.
  select unit_price into v_price from public.product_prices
    where product_id = p_product and status = 'ACTIVE' and effective_date <= v_date order by effective_date desc limit 1;
  if v_price is null then raise exception 'NO_PRICE'; end if;
  if p_id is null then
    insert into public.sale_lines (sale_id, product_id, qty, unit_price, stamp_by) values (v_sale, p_product, p_qty, v_price, public._stamp_name()) returning id into v_id;
    perform public._audit('ADD_SALE_LINE', v_id);
  else
    update public.sale_lines set product_id = p_product, qty = p_qty, unit_price = v_price, stamp_action = 'EDITED', stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
    perform public._audit('EDIT_SALE_LINE', p_id);
    perform public._check_not_overpaid(v_sale);
  end if;
  return v_id;
end $$;

create or replace function public.line_set_deleted(p_id uuid, p_deleted boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_sale uuid;
begin
  if p_deleted and not public.has_right('sale.line_delete') then raise exception 'NOT_ALLOWED'; end if;
  if not p_deleted and not public.is_staff() then raise exception 'NOT_ALLOWED'; end if;
  update public.sale_lines set status = case when p_deleted then 'INACTIVE' else 'ACTIVE' end,
    stamp_action = case when p_deleted then 'DELETED' else 'RESTORED' end, stamp_by = public._stamp_name(), stamp_at = now() where id = p_id returning sale_id into v_sale;
  if v_sale is null then raise exception 'NOT_FOUND'; end if;
  perform public._audit(case when p_deleted then 'DELETE_SALE_LINE' else 'RESTORE_SALE_LINE' end, p_id);
  if p_deleted then perform public._check_not_overpaid(v_sale); end if;
end $$;

create or replace function public.payment_save(p_sale uuid, p_date date, p_amount numeric) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_total numeric; v_paid numeric;
begin
  if not public.has_right('sale.edit') then raise exception 'NOT_ALLOWED'; end if;
  if p_date is null or p_amount is null or p_amount <= 0 then raise exception 'BAD_INPUT'; end if;
  if not exists (select 1 from public.sales where id = p_sale and status = 'ACTIVE') then raise exception 'NOT_FOUND'; end if;
  select coalesce(sum(line_total), 0) into v_total from public.sale_lines where sale_id = p_sale and status = 'ACTIVE';
  select coalesce(sum(amount), 0) into v_paid from public.payments where sale_id = p_sale;
  if round(p_amount, 2) > v_total - v_paid then raise exception 'OVERPAY'; end if;
  insert into public.payments (sale_id, pay_date, amount, stamp_by) values (p_sale, p_date, round(p_amount, 2), public._stamp_name()) returning id into v_id;
  perform public._audit('ADD_PAYMENT', v_id);
  return v_id;
end $$;

-- 6. Reports (each checks its own right and returns rows as JSON) -----------------
create or replace function public.report_top_customers(p_from date, p_to date, p_n int) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.top_customers') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('rank', row_number() over (order by sum(l.line_total) desc, c.cust_no), 'cust_no', c.cust_no, 'name', c.name, 'total', sum(l.line_total))
    from public.sales s join public.sale_lines l on l.sale_id = s.id and l.status = 'ACTIVE' join public.customers c on c.id = s.customer_id
    where s.status = 'ACTIVE' and s.sale_date between p_from and p_to group by c.id, c.cust_no, c.name order by sum(l.line_total) desc, c.cust_no limit greatest(p_n, 1);
end $$;

create or replace function public.report_product_master() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.product_master') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('prod_code', p.prod_code, 'description', p.description, 'unit', p.unit, 'price', cp.unit_price)
    from public.products p left join lateral (select pp.unit_price from public.product_prices pp where pp.product_id = p.id and pp.status = 'ACTIVE'
      and pp.effective_date <= current_date order by pp.effective_date desc limit 1) cp on true
    where p.status = 'ACTIVE' order by p.prod_code;
end $$;

create or replace function public.report_top_products(p_from date, p_to date, p_n int) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.top_products') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('rank', row_number() over (order by sum(l.line_total) desc, p.prod_code), 'prod_code', p.prod_code, 'description', p.description, 'qty', sum(l.qty), 'amount', sum(l.line_total))
    from public.sales s join public.sale_lines l on l.sale_id = s.id and l.status = 'ACTIVE' join public.products p on p.id = l.product_id
    where s.status = 'ACTIVE' and s.sale_date between p_from and p_to group by p.id, p.prod_code, p.description order by sum(l.line_total) desc, p.prod_code limit greatest(p_n, 1);
end $$;

create or replace function public.report_active_employees() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.active_employees') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('emp_no', e.emp_no, 'last_name', e.last_name, 'first_name', e.first_name, 'gender', e.gender, 'birth_date', e.birth_date, 'hire_date', e.hire_date)
    from public.employees e where e.status = 'ACTIVE' and e.sep_date is null order by e.emp_no;
end $$;

create or replace function public.report_all_employees() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.all_employees') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('emp_no', e.emp_no, 'last_name', e.last_name, 'first_name', e.first_name, 'gender', e.gender, 'birth_date', e.birth_date, 'hire_date', e.hire_date,
      'sep_date', e.sep_date, 'state', case when e.sep_date is null then 'Active' else 'Separated' end)
    from public.employees e where e.status = 'ACTIVE' order by e.emp_no;
end $$;

create or replace function public.report_employee_list() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.employee_history') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('id', e.id, 'label', e.emp_no || ' ' || e.first_name || ' ' || e.last_name) from public.employees e where e.status = 'ACTIVE' order by e.emp_no;
end $$;

create or replace function public.report_employee_history(p_employee uuid) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.employee_history') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('date', h.effective_date, 'job', j.job_no || ' ' || j.description, 'dept', d.dept_no || ' ' || d.name, 'salary', h.salary)
    from public.job_history h join public.jobs j on j.id = h.job_id join public.departments d on d.id = h.dept_id where h.employee_id = p_employee order by h.effective_date desc;
end $$;

create or replace function public.report_top_sales(p_from date, p_to date, p_n int) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_right('report.top_sales') then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('rank', row_number() over (order by sum(l.line_total) desc, s.trans_no), 'trans_no', s.trans_no, 'date', s.sale_date,
      'customer', c.name, 'employee', e.first_name || ' ' || e.last_name, 'total', sum(l.line_total))
    from public.sales s join public.sale_lines l on l.sale_id = s.id and l.status = 'ACTIVE' join public.customers c on c.id = s.customer_id join public.employees e on e.id = s.employee_id
    where s.status = 'ACTIVE' and s.sale_date between p_from and p_to group by s.id, s.trans_no, s.sale_date, c.name, e.first_name, e.last_name
    order by sum(l.line_total) desc, s.trans_no limit greatest(p_n, 1);
end $$;

-- 7. Audit log search (Superadmin only) -------------------------------------------
create or replace function public.audit_search(p_entity text, p_verb text, p_user text, p_from date, p_to date) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.app_role() is distinct from 'SUPERADMIN' then raise exception 'NOT_ALLOWED'; end if;
  return query select jsonb_build_object('at', a.at, 'user', coalesce(u.username, 'system'),
      'entity', substr(a.action, position('_' in a.action) + 1), 'verb', split_part(a.action, '_', 1),
      'row', coalesce(c.cust_no, pr.prod_code, d.dept_no, j.job_no, em.emp_no, s.trans_no, pay.or_no, pf.username), 'detail', a.detail)
    from public.audit_log a
    left join public.profiles u on u.id::text = a.actor_id::text
    left join public.customers c on c.id::text = a.target_id::text left join public.products pr on pr.id::text = a.target_id::text
    left join public.departments d on d.id::text = a.target_id::text left join public.jobs j on j.id::text = a.target_id::text
    left join public.employees em on em.id::text = a.target_id::text left join public.sales s on s.id::text = a.target_id::text
    left join public.payments pay on pay.id::text = a.target_id::text left join public.profiles pf on pf.id::text = a.target_id::text
    where (coalesce(p_entity, '') = '' or substr(a.action, position('_' in a.action) + 1) = p_entity)
      and (coalesce(p_verb, '') = '' or split_part(a.action, '_', 1) = p_verb)
      and (coalesce(p_user, '') = '' or u.username = p_user)
      and (p_from is null or a.at >= p_from) and (p_to is null or a.at < p_to + 1)
    order by a.at desc limit 500;
end $$;

-- 8. Permissions on the new functions ----------------------------------------------
revoke all on function public.sale_customers(), public.sale_employees(), public.sale_products(),
  public.sale_save(uuid, date, uuid, uuid), public.sale_set_deleted(uuid, boolean), public.line_save(uuid, uuid, uuid, integer), public.line_set_deleted(uuid, boolean),
  public.payment_save(uuid, date, numeric), public.report_top_customers(date, date, int), public.report_product_master(), public.report_top_products(date, date, int),
  public.report_active_employees(), public.report_all_employees(), public.report_employee_list(), public.report_employee_history(uuid), public.report_top_sales(date, date, int),
  public.audit_search(text, text, text, date, date) from public;
grant execute on function public.sale_customers(), public.sale_employees(), public.sale_products(),
  public.sale_save(uuid, date, uuid, uuid), public.sale_set_deleted(uuid, boolean), public.line_save(uuid, uuid, uuid, integer), public.line_set_deleted(uuid, boolean),
  public.payment_save(uuid, date, numeric), public.report_top_customers(date, date, int), public.report_product_master(), public.report_top_products(date, date, int),
  public.report_active_employees(), public.report_all_employees(), public.report_employee_list(), public.report_employee_history(uuid), public.report_top_sales(date, date, int),
  public.audit_search(text, text, text, date, date) to authenticated;
