# Hope, Inc. ERP: what is built and what is left

## Built (all four sprints)
**Sprint 1**: Log in, Register, Forgot / Reset password; app shell; Dashboard; User Management
(approve, edit, block/unblock, Rights dialog with 36 rights, Add user by email invite, last-Superadmin guard).
**Sprint 2**: Customers and Products with price history, soft delete and Restore, Status and Stamp columns for Admins.
**Sprint 3**: Human Resources: Employees, Jobs, Departments, Employee profile with job history timeline.
**Sprint 4**: Sales with line items (price taken from the price history on the sales date), payments and
balances, 7 reports (Print / Save as PDF through the browser print dialog), Audit log viewer (Superadmin).

Run order in Supabase SQL Editor: sql/01-schema.sql to sql/05-sprint4.sql.
Deploy js/edge-function-admin-create-user.ts as the Edge Function admin-create-user (needed for Add user).

## Still open
1. Live test: everything was checked with sample data only. Click through each screen against your Supabase project
   and report anything odd (mark this zip READY after that).
2. Audit log: Before / After values are not recorded yet; the Details column shows what each action stored.
3. Rights on Admin accounts (the design shows it; this build gives Admins every right).
4. Payments are record-only (no edit or delete). Recording a payment uses the Edit Sale right (no separate payment right in the 36).
5. Add line item shows the price rule as a hint, not a live price preview.
6. System Settings was replaced by Audit Log in the menu.

7. Old data: sql/06-migrate-old-data.sql copies the older tables (customer, product, employee, sales_old, ...) into the new ones. Run it once, read the report, then decide whether to drop the old tables.
