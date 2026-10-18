# describe goldens

Real `psql` 17.11 output (`psql -X -q -c '<command>'`) against PostgreSQL
18.6 for this schema and these roles; `describer_test.dart` feeds the same
catalog rows to the library through a fake query callback and expects the
same text.

```sql
create table users (id int generated always as identity primary key,
  email text not null check (email <> ''), created timestamptz default now());
create table orders (id bigserial primary key, user_id int references users(id),
  total numeric(10,2));
create index orders_user_idx on orders (user_id) where total > 0;
create view big_orders as select * from orders where total > 100;
create role alice superuser createrole createdb replication bypassrls login;
create role bob noinherit nologin connection limit 3
  valid until '2030-01-01 00:00:00+00';
```

| File | Command |
| --- | --- |
| describe_users.txt | `\d users` |
| describe_sequence.txt | `\d orders_id_seq` |
| describe_index.txt | `\d orders_user_idx` |
| describe_view_verbose.txt | `\d+ big_orders` |
| list_tables.txt | `\dt` |
| list_roles.txt | `\du alice\|bob` |
