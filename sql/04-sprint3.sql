-- Sprint 3 backend: Departments, Jobs, Employees and Job history.
-- Run AFTER 01-schema.sql, 02-sprint1.sql and 03-sprint2.sql, in Supabase SQL Editor. Safe to run again.

-- 0. Safety check: stop early, with a clear message, if an old table with the same name is in the way ----
do $$
declare t text;
begin
  foreach t in array array['departments', 'jobs', 'employees', 'job_history'] loop
    if to_regclass('public.' || t) is not null and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'id') then
      raise exception 'Table public.% already exists but has no id column, so these scripts did not create it. Open Table Editor to check it. If you do not need it, drop it and run this file again.', t;
    end if;
  end loop;
end $$;

-- 1. Tables ----------------------------------------------------------------
create sequence if not exists public.department_no_seq;
create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  dept_no text not null unique default ('D-' || lpad(nextval('public.department_no_seq')::text, 3, '0')),
  name text not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  stamp_action text not null default 'CREATED', stamp_by text not null default 'system', stamp_at timestamptz not null default now()
);
create sequence if not exists public.job_no_seq;
create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  job_no text not null unique default ('J-' || lpad(nextval('public.job_no_seq')::text, 3, '0')),
  description text not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  stamp_action text not null default 'CREATED', stamp_by text not null default 'system', stamp_at timestamptz not null default now()
);
create sequence if not exists public.employee_no_seq;
create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  emp_no text not null unique default ('E-' || lpad(nextval('public.employee_no_seq')::text, 3, '0')),
  last_name text not null,
  first_name text not null,
  gender text not null check (gender in ('F','M')),
  birth_date date not null,
  hire_date date not null,
  sep_date date,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  stamp_action text not null default 'CREATED', stamp_by text not null default 'system', stamp_at timestamptz not null default now(),
  check (hire_date >= birth_date), check (sep_date is null or sep_date >= hire_date)
);
create table if not exists public.job_history (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees (id) on delete cascade,
  effective_date date not null,
  job_id uuid not null references public.jobs (id),
  dept_id uuid not null references public.departments (id),
  salary numeric(12,2) not null check (salary >= 0),
  stamp_by text not null default 'system', stamp_at timestamptz not null default now(),
  unique (employee_id, effective_date)
);

-- 2. Row Level Security -----------------------------------------------------
-- Any HR right lets a user read HR lists. Job history and salary need the View Job History right.
alter table public.departments enable row level security;
alter table public.jobs        enable row level security;
alter table public.employees   enable row level security;
alter table public.job_history enable row level security;
drop policy if exists "Read departments" on public.departments;
create policy "Read departments" on public.departments for select to authenticated using (public.has_access('hr.') and (status = 'ACTIVE' or public.is_staff()));
drop policy if exists "Read jobs" on public.jobs;
create policy "Read jobs" on public.jobs for select to authenticated using (public.has_access('hr.') and (status = 'ACTIVE' or public.is_staff()));
drop policy if exists "Read employees" on public.employees;
create policy "Read employees" on public.employees for select to authenticated using (public.has_access('hr.') and (status = 'ACTIVE' or public.is_staff()));
drop policy if exists "Read job history" on public.job_history;
create policy "Read job history" on public.job_history for select to authenticated using (public.has_right('hr.history_view'));

-- 3. Actions ------------------------------------------------------------------
create or replace function public.department_save(p_id uuid, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if btrim(coalesce(p_name, '')) = '' then raise exception 'BAD_INPUT'; end if;
  if p_id is null then
    if not public.has_right('hr.dept_add') then raise exception 'NOT_ALLOWED'; end if;
    insert into public.departments (name, stamp_by) values (btrim(p_name), public._stamp_name()) returning id into v_id;
    perform public._audit('ADD_DEPARTMENT', v_id);
  else
    if not public.has_right('hr.dept_edit') then raise exception 'NOT_ALLOWED'; end if;
    update public.departments set name = btrim(p_name), stamp_action = 'EDITED', stamp_by = public._stamp_name(), stamp_at = now() where id = p_id and status = 'ACTIVE';
    if not found then raise exception 'NOT_FOUND'; end if;
    perform public._audit('EDIT_DEPARTMENT', p_id);
  end if;
  return v_id;
end $$;

create or replace function public.department_set_deleted(p_id uuid, p_deleted boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_deleted and not public.has_right('hr.dept_delete') then raise exception 'NOT_ALLOWED'; end if;
  if not p_deleted and not public.is_staff() then raise exception 'NOT_ALLOWED'; end if;
  if p_deleted and exists (select 1 from public.job_history where dept_id = p_id) then raise exception 'IN_USE'; end if;
  update public.departments set status = case when p_deleted then 'INACTIVE' else 'ACTIVE' end,
    stamp_action = case when p_deleted then 'DELETED' else 'RESTORED' end, stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._audit(case when p_deleted then 'DELETE_DEPARTMENT' else 'RESTORE_DEPARTMENT' end, p_id);
end $$;

create or replace function public.job_save(p_id uuid, p_description text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if btrim(coalesce(p_description, '')) = '' then raise exception 'BAD_INPUT'; end if;
  if p_id is null then
    if not public.has_right('hr.job_add') then raise exception 'NOT_ALLOWED'; end if;
    insert into public.jobs (description, stamp_by) values (btrim(p_description), public._stamp_name()) returning id into v_id;
    perform public._audit('ADD_JOB', v_id);
  else
    if not public.has_right('hr.job_edit') then raise exception 'NOT_ALLOWED'; end if;
    update public.jobs set description = btrim(p_description), stamp_action = 'EDITED', stamp_by = public._stamp_name(), stamp_at = now() where id = p_id and status = 'ACTIVE';
    if not found then raise exception 'NOT_FOUND'; end if;
    perform public._audit('EDIT_JOB', p_id);
  end if;
  return v_id;
end $$;

create or replace function public.job_set_deleted(p_id uuid, p_deleted boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_deleted and not public.has_right('hr.job_delete') then raise exception 'NOT_ALLOWED'; end if;
  if not p_deleted and not public.is_staff() then raise exception 'NOT_ALLOWED'; end if;
  if p_deleted and exists (select 1 from public.job_history where job_id = p_id) then raise exception 'IN_USE'; end if;
  update public.jobs set status = case when p_deleted then 'INACTIVE' else 'ACTIVE' end,
    stamp_action = case when p_deleted then 'DELETED' else 'RESTORED' end, stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._audit(case when p_deleted then 'DELETE_JOB' else 'RESTORE_JOB' end, p_id);
end $$;

create or replace function public.employee_save(p_id uuid, p_last text, p_first text, p_gender text, p_birth date, p_hire date, p_sep date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if btrim(coalesce(p_last, '')) = '' or btrim(coalesce(p_first, '')) = '' or p_gender not in ('F','M')
     or p_birth is null or p_hire is null or p_hire < p_birth or (p_sep is not null and p_sep < p_hire) then raise exception 'BAD_INPUT'; end if;
  if p_id is null then
    if not public.has_right('hr.emp_add') then raise exception 'NOT_ALLOWED'; end if;
    insert into public.employees (last_name, first_name, gender, birth_date, hire_date, sep_date, stamp_by)
      values (btrim(p_last), btrim(p_first), p_gender, p_birth, p_hire, p_sep, public._stamp_name()) returning id into v_id;
    perform public._audit('ADD_EMPLOYEE', v_id);
  else
    if not public.has_right('hr.emp_edit') then raise exception 'NOT_ALLOWED'; end if;
    update public.employees set last_name = btrim(p_last), first_name = btrim(p_first), gender = p_gender, birth_date = p_birth, hire_date = p_hire, sep_date = p_sep,
      stamp_action = 'EDITED', stamp_by = public._stamp_name(), stamp_at = now() where id = p_id and status = 'ACTIVE';
    if not found then raise exception 'NOT_FOUND'; end if;
    perform public._audit('EDIT_EMPLOYEE', p_id);
  end if;
  return v_id;
end $$;

create or replace function public.employee_set_deleted(p_id uuid, p_deleted boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_deleted and not public.has_right('hr.emp_delete') then raise exception 'NOT_ALLOWED'; end if;
  if not p_deleted and not public.is_staff() then raise exception 'NOT_ALLOWED'; end if;
  update public.employees set status = case when p_deleted then 'INACTIVE' else 'ACTIVE' end,
    stamp_action = case when p_deleted then 'DELETED' else 'RESTORED' end, stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._audit(case when p_deleted then 'DELETE_EMPLOYEE' else 'RESTORE_EMPLOYEE' end, p_id);
end $$;

create or replace function public.history_save(p_id uuid, p_employee uuid, p_date date, p_job uuid, p_dept uuid, p_salary numeric) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if p_date is null or p_job is null or p_dept is null or p_salary is null or p_salary < 0 then raise exception 'BAD_INPUT'; end if;
  begin
    if p_id is null then
      if not public.has_right('hr.history_add') then raise exception 'NOT_ALLOWED'; end if;
      if not exists (select 1 from public.employees where id = p_employee and status = 'ACTIVE') then raise exception 'NOT_FOUND'; end if;
      insert into public.job_history (employee_id, effective_date, job_id, dept_id, salary, stamp_by)
        values (p_employee, p_date, p_job, p_dept, round(p_salary, 2), public._stamp_name()) returning id into v_id;
      perform public._audit('ADD_JOB_HISTORY', v_id);
    else
      if not public.has_right('hr.history_edit') then raise exception 'NOT_ALLOWED'; end if;
      update public.job_history set effective_date = p_date, job_id = p_job, dept_id = p_dept, salary = round(p_salary, 2), stamp_by = public._stamp_name(), stamp_at = now() where id = p_id;
      if not found then raise exception 'NOT_FOUND'; end if;
      perform public._audit('EDIT_JOB_HISTORY', p_id);
    end if;
  exception when unique_violation then raise exception 'DUPLICATE';
  end;
  return v_id;
end $$;

-- Job history entries are removed for good; the audit log keeps a record of the deletion.
create or replace function public.history_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_right('hr.history_delete') then raise exception 'NOT_ALLOWED'; end if;
  delete from public.job_history where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._audit('DELETE_JOB_HISTORY', p_id);
end $$;

revoke all on function public.department_save(uuid, text), public.department_set_deleted(uuid, boolean), public.job_save(uuid, text), public.job_set_deleted(uuid, boolean),
  public.employee_save(uuid, text, text, text, date, date, date), public.employee_set_deleted(uuid, boolean),
  public.history_save(uuid, uuid, date, uuid, uuid, numeric), public.history_delete(uuid) from public;
grant execute on function public.department_save(uuid, text), public.department_set_deleted(uuid, boolean), public.job_save(uuid, text), public.job_set_deleted(uuid, boolean),
  public.employee_save(uuid, text, text, text, date, date, date), public.employee_set_deleted(uuid, boolean),
  public.history_save(uuid, uuid, date, uuid, uuid, numeric), public.history_delete(uuid) to authenticated;
