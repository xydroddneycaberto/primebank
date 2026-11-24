-- One-time import of the OLD tables into the NEW ones.
-- Old tables used: customer, product, pricehist, department, job, employee, jobhistory, sales_old, salesdetail, payment.
-- Run AFTER 01 to 05. Old tables are only read, never changed or dropped. Safe to run again: rows already copied are skipped.
-- Old codes are kept as they are (C0001, AD0001, TR000001, OR000001). New records created in the app use the new format (C-001, P-001, ...).
-- The last result shows what was copied and what was not, and why.

-- 0. Safety check ------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['customer','product','pricehist','department','job','employee','jobhistory','sales_old','salesdetail','payment'] loop
    if to_regclass('public.' || t) is null then
      raise exception 'Old table public.% was not found. If you renamed or dropped it, this script cannot run.', t;
    end if;
  end loop;
  foreach t in array array['customers','products','product_prices','departments','jobs','employees','job_history','sales','sale_lines','payments'] loop
    if to_regclass('public.' || t) is null then
      raise exception 'New table public.% was not found. Run the numbered SQL files 01 to 05 first.', t;
    end if;
  end loop;
end $$;

-- 1. Small helpers (removed again at the end) --------------------------------------------
create or replace function public._mig_action(s text) returns text language sql immutable as $$
  select case upper(split_part(coalesce(s, ''), ' ', 1)) when 'EDIT' then 'EDITED' when 'DEL' then 'DELETED' when 'DELETE' then 'DELETED' when 'RESTORE' then 'RESTORED' else 'CREATED' end
$$;
create or replace function public._mig_by(s text) returns text language sql immutable as $$
  select coalesce(nullif(split_part(coalesce(s, ''), ' ', 2), ''), 'system')
$$;
create or replace function public._mig_at(s text) returns timestamptz language plpgsql stable as $$
declare m text[];
begin
  m := regexp_match(coalesce(s, ''), '(\d{4}-\d{2}-\d{2} +\d{1,2}:\d{2} *[AaPp][Mm])');
  if m is null then return now(); end if;
  return to_timestamp(regexp_replace(m[1], ' +', ' ', 'g'), 'YYYY-MM-DD HH12:MI AM');
exception when others then return now();
end $$;
create or replace function public._mig_terms(s text) returns text language sql immutable as $$
  select case upper(btrim(coalesce(s, '')))
    when '15D' then 'Net 15' when 'NET 15' then 'Net 15' when '30D' then 'Net 30' when 'NET 30' then 'Net 30'
    when '45D' then 'Net 45' when 'NET 45' then 'Net 45' when 'COD' then 'COD' when 'PREPAID' then 'Prepaid' when 'PRE' then 'Prepaid' else null end
$$;

-- 2. Copy the data (parents first) -------------------------------------------------------
insert into public.departments (dept_no, name, status, stamp_action, stamp_by, stamp_at)
select btrim(o.deptcode), btrim(o.deptname), case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.department o where btrim(coalesce(o.deptcode, '')) <> '' and btrim(coalesce(o.deptname, '')) <> ''
on conflict do nothing;

insert into public.jobs (job_no, description, status, stamp_action, stamp_by, stamp_at)
select btrim(o.jobcode), btrim(o.jobdesc), case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.job o where btrim(coalesce(o.jobcode, '')) <> '' and btrim(coalesce(o.jobdesc, '')) <> ''
on conflict do nothing;

insert into public.customers (cust_no, name, address, pay_terms, status, stamp_action, stamp_by, stamp_at)
select btrim(o.custno), btrim(o.custname), btrim(coalesce(o.address, '')), public._mig_terms(o.payterm), case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end,
  public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.customer o where btrim(coalesce(o.custno, '')) <> '' and btrim(coalesce(o.custname, '')) <> '' and public._mig_terms(o.payterm) is not null
on conflict do nothing;

insert into public.products (prod_code, description, unit, status, stamp_action, stamp_by, stamp_at)
select btrim(o.prodcode), btrim(o.description), btrim(o.unit), case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.product o where btrim(coalesce(o.prodcode, '')) <> '' and btrim(coalesce(o.description, '')) <> '' and btrim(coalesce(o.unit, '')) <> ''
on conflict do nothing;

insert into public.product_prices (product_id, effective_date, unit_price, status, stamp_action, stamp_by, stamp_at)
select p.id, o.effdate, o.unitprice, case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.pricehist o join public.products p on p.prod_code = btrim(o.prodcode)
where o.effdate is not null and o.unitprice is not null and o.unitprice >= 0
  and not exists (select 1 from public.product_prices x where x.product_id = p.id and x.effective_date = o.effdate and x.unit_price = o.unitprice)
on conflict do nothing;

insert into public.employees (emp_no, last_name, first_name, gender, birth_date, hire_date, sep_date, status, stamp_action, stamp_by, stamp_at)
select btrim(o.empno), btrim(o.lastname), btrim(o.firstname), upper(btrim(o.gender)), o.birthdate, o.hiredate, o.sepdate,
  case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.employee o
where btrim(coalesce(o.empno, '')) <> '' and btrim(coalesce(o.lastname, '')) <> '' and btrim(coalesce(o.firstname, '')) <> '' and upper(btrim(o.gender)) in ('F', 'M')
  and o.birthdate is not null and o.hiredate is not null and o.hiredate >= o.birthdate and (o.sepdate is null or o.sepdate >= o.hiredate)
on conflict do nothing;

-- Job history entries have no deleted state in the new design, so rows marked deleted in the old table are not copied.
insert into public.job_history (employee_id, effective_date, job_id, dept_id, salary, stamp_by, stamp_at)
select e.id, o.effdate, j.id, d.id, o.salary, public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.jobhistory o
join public.employees e on e.emp_no = btrim(o.empno)
join public.jobs j on j.job_no = btrim(o.jobcode)
join public.departments d on d.dept_no = btrim(o.deptcode)
where not coalesce(o.is_deleted, false) and o.effdate is not null and o.salary is not null and o.salary >= 0
on conflict do nothing;

insert into public.sales (trans_no, sale_date, customer_id, employee_id, status, stamp_action, stamp_by, stamp_at)
select btrim(o.transno), o.salesdate, c.id, e.id, case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.sales_old o
join public.customers c on c.cust_no = btrim(o.custno)
join public.employees e on e.emp_no = btrim(o.empno)
where btrim(coalesce(o.transno, '')) <> '' and o.salesdate is not null
on conflict do nothing;

-- Each line gets the price in force on its sales date, the same rule the app uses. Sales that already have lines are left alone.
insert into public.sale_lines (sale_id, product_id, qty, unit_price, status, stamp_action, stamp_by, stamp_at)
select s.id, p.id, o.quantity::integer, pr.unit_price, case when o.is_deleted then 'INACTIVE' else 'ACTIVE' end, public._mig_action(o.stamp), public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.salesdetail o
join public.sales s on s.trans_no = btrim(o.transno)
join public.products p on p.prod_code = btrim(o.prodcode)
join lateral (select pp.unit_price from public.product_prices pp where pp.product_id = p.id and pp.status = 'ACTIVE' and pp.effective_date <= s.sale_date
              order by pp.effective_date desc limit 1) pr on true
where o.quantity >= 1 and o.quantity = round(o.quantity)
  and not exists (select 1 from public.sale_lines x where x.sale_id = s.id);

insert into public.payments (sale_id, or_no, pay_date, amount, stamp_by, stamp_at)
select s.id, btrim(o.orno), o.paydate, o.amount, public._mig_by(o.stamp), public._mig_at(o.stamp)
from public.payment o join public.sales s on s.trans_no = btrim(o.transno)
where not coalesce(o.is_deleted, false) and btrim(coalesce(o.orno, '')) <> '' and o.paydate is not null and o.amount is not null and o.amount > 0
on conflict do nothing;

-- 3. Report -------------------------------------------------------------------------------
create temp table _mig_report (n int generated always as identity, step text, old_rows bigint, copied bigint, not_copied bigint, why text);

insert into _mig_report (step, old_rows, copied, why)
select 'Departments', (select count(*) from public.department),
  (select count(*) from public.department o where exists (select 1 from public.departments x where x.dept_no = btrim(o.deptcode))),
  format('%s have a blank code or name', (select count(*) from public.department o where btrim(coalesce(o.deptcode, '')) = '' or btrim(coalesce(o.deptname, '')) = ''));
insert into _mig_report (step, old_rows, copied, why)
select 'Jobs', (select count(*) from public.job),
  (select count(*) from public.job o where exists (select 1 from public.jobs x where x.job_no = btrim(o.jobcode))),
  format('%s have a blank code or description', (select count(*) from public.job o where btrim(coalesce(o.jobcode, '')) = '' or btrim(coalesce(o.jobdesc, '')) = ''));
insert into _mig_report (step, old_rows, copied, why)
select 'Customers', (select count(*) from public.customer),
  (select count(*) from public.customer o where exists (select 1 from public.customers x where x.cust_no = btrim(o.custno))),
  format('%s have a pay term other than 15D, 30D, 45D, COD or Prepaid; %s have a blank code or name',
    (select count(*) from public.customer o where public._mig_terms(o.payterm) is null),
    (select count(*) from public.customer o where btrim(coalesce(o.custno, '')) = '' or btrim(coalesce(o.custname, '')) = ''));
insert into _mig_report (step, old_rows, copied, why)
select 'Products', (select count(*) from public.product),
  (select count(*) from public.product o where exists (select 1 from public.products x where x.prod_code = btrim(o.prodcode))),
  format('%s have a blank code, description or unit', (select count(*) from public.product o where btrim(coalesce(o.prodcode, '')) = '' or btrim(coalesce(o.description, '')) = '' or btrim(coalesce(o.unit, '')) = ''));
insert into _mig_report (step, old_rows, copied, why)
select 'Product prices', (select count(*) from public.pricehist),
  (select count(*) from public.pricehist o where exists (select 1 from public.product_prices x join public.products p on p.id = x.product_id
     where p.prod_code = btrim(o.prodcode) and x.effective_date = o.effdate and x.unit_price = o.unitprice)),
  format('%s point to an unknown product; %s have a negative price or no date; the rest repeat a price already set for that date',
    (select count(*) from public.pricehist o where not exists (select 1 from public.products p where p.prod_code = btrim(o.prodcode))),
    (select count(*) from public.pricehist o where o.effdate is null or o.unitprice is null or o.unitprice < 0));
insert into _mig_report (step, old_rows, copied, why)
select 'Employees', (select count(*) from public.employee),
  (select count(*) from public.employee o where exists (select 1 from public.employees x where x.emp_no = btrim(o.empno))),
  format('%s break a rule (gender not F or M, missing dates, hired before birth, or separated before hire)',
    (select count(*) from public.employee o where upper(btrim(o.gender)) not in ('F', 'M') or o.birthdate is null or o.hiredate is null or o.hiredate < o.birthdate or (o.sepdate is not null and o.sepdate < o.hiredate)));
insert into _mig_report (step, old_rows, copied, why)
select 'Job history', (select count(*) from public.jobhistory),
  (select count(*) from public.jobhistory o where not coalesce(o.is_deleted, false) and exists
     (select 1 from public.job_history h join public.employees e on e.id = h.employee_id where e.emp_no = btrim(o.empno) and h.effective_date = o.effdate)),
  format('%s are marked deleted (not copied by design); %s point to a missing employee, job or department; the rest repeat an employee and date',
    (select count(*) from public.jobhistory o where coalesce(o.is_deleted, false)),
    (select count(*) from public.jobhistory o where not coalesce(o.is_deleted, false) and (
       not exists (select 1 from public.employees e where e.emp_no = btrim(o.empno)) or not exists (select 1 from public.jobs j where j.job_no = btrim(o.jobcode))
       or not exists (select 1 from public.departments d where d.dept_no = btrim(o.deptcode)))));
insert into _mig_report (step, old_rows, copied, why)
select 'Sales', (select count(*) from public.sales_old),
  (select count(*) from public.sales_old o where exists (select 1 from public.sales x where x.trans_no = btrim(o.transno))),
  format('%s point to a customer or employee that was not copied', (select count(*) from public.sales_old o where
    not exists (select 1 from public.customers c where c.cust_no = btrim(o.custno)) or not exists (select 1 from public.employees e where e.emp_no = btrim(o.empno))));
insert into _mig_report (step, old_rows, copied, why)
select 'Sale lines', (select count(*) from public.salesdetail),
  (select count(*) from public.salesdetail o where exists (select 1 from public.sale_lines l join public.sales s on s.id = l.sale_id join public.products p on p.id = l.product_id
     where s.trans_no = btrim(o.transno) and p.prod_code = btrim(o.prodcode))),
  format('%s have a quantity that is not a whole number of 1 or more; %s point to a sale or product that was not copied; %s have no price in force on the sales date',
    (select count(*) from public.salesdetail o where o.quantity is null or o.quantity < 1 or o.quantity <> round(o.quantity)),
    (select count(*) from public.salesdetail o where not exists (select 1 from public.sales s where s.trans_no = btrim(o.transno)) or not exists (select 1 from public.products p where p.prod_code = btrim(o.prodcode))),
    (select count(*) from public.salesdetail o join public.sales s on s.trans_no = btrim(o.transno) join public.products p on p.prod_code = btrim(o.prodcode)
      where o.quantity >= 1 and o.quantity = round(o.quantity) and not exists (select 1 from public.product_prices pp where pp.product_id = p.id and pp.status = 'ACTIVE' and pp.effective_date <= s.sale_date)));
insert into _mig_report (step, old_rows, copied, why)
select 'Payments', (select count(*) from public.payment),
  (select count(*) from public.payment o where exists (select 1 from public.payments x where x.or_no = btrim(o.orno))),
  format('%s are marked deleted (not copied by design); %s point to a sale that was not copied or have an amount of zero or less',
    (select count(*) from public.payment o where coalesce(o.is_deleted, false)),
    (select count(*) from public.payment o where not coalesce(o.is_deleted, false) and (o.amount is null or o.amount <= 0 or not exists (select 1 from public.sales s where s.trans_no = btrim(o.transno)))));
update _mig_report set not_copied = old_rows - copied;

insert into _mig_report (step, why)
select 'Check: sales paid more than their total',
  format('%s sales have payments above their line total (shown as a negative balance). Usually the old prices differ from the price history.',
    (select count(*) from (select s.id from public.sales s
       left join (select sale_id, sum(line_total) t from public.sale_lines where status = 'ACTIVE' group by sale_id) l on l.sale_id = s.id
       left join (select sale_id, sum(amount) p from public.payments group by sale_id) y on y.sale_id = s.id
       where coalesce(y.p, 0) > coalesce(l.t, 0)) bad));

insert into public.audit_log (action, detail) values ('IMPORT_OLD_DATA', (select jsonb_object_agg(step, jsonb_build_object('old', old_rows, 'copied', copied)) from _mig_report where old_rows is not null));

drop function public._mig_action(text), public._mig_by(text), public._mig_at(text), public._mig_terms(text);

select step, old_rows, copied, not_copied, why from _mig_report order by n;
