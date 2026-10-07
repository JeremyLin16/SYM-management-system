-- ============================================================
-- 团契餐卡管理系统 —— Supabase 建表脚本（全新安装用）
-- 用法：Supabase 后台 → 左侧 SQL Editor → New query →
--      把本文件全部内容粘贴进去 → 点 Run
-- 整个脚本可以重复运行，不会重复建表或报错。
-- 已经装过旧版的，不用跑这个，跑 migration.sql 就行。
-- ============================================================

-- ---------- 成员 ----------
create table if not exists public.members (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null,
  pinyin      text        not null default '',   -- 拼音首字母，如 "zs"，用于搜索
  group_name  text        not null default '',   -- 所属小组，空字符串 = 未分组
  active      boolean     not null default true, -- false = 已隐藏/离开
  created_at  timestamptz not null default now()
);

-- ---------- 饭卡（20欧5次）----------
create table if not exists public.meal_cards (
  id          uuid        primary key default gen_random_uuid(),
  member_id   uuid        not null references public.members(id) on delete cascade,
  is_paid     boolean     not null default false,  -- true = 已收20欧
  paid_at     timestamptz,                         -- 实际收到 20 欧的时间（补交的算补交那天）
  status      text        not null default 'ACTIVE'
                          check (status in ('ACTIVE', 'EXHAUSTED', 'ARCHIVED')),
  created_at  timestamptz not null default now()
);

-- ---------- 打卡记录（Excel 里的日期格子）----------
create table if not exists public.card_usages (
  id          uuid        primary key default gen_random_uuid(),
  card_id     uuid        not null references public.meal_cards(id) on delete cascade,
  member_id   uuid        not null references public.members(id) on delete cascade,
  used_date   date        not null default ((now() at time zone 'Europe/Madrid')::date),
  created_at  timestamptz not null default now()
  -- 故意不加"每天一次"的限制：一张卡经本人同意可以在同一天给别人用。
);

-- ---------- 散客流水（4欧单次）----------
create table if not exists public.cash_logs (
  id          uuid        primary key default gen_random_uuid(),
  log_date    date        not null default ((now() at time zone 'Europe/Madrid')::date),
  amount      numeric     not null default 4,
  operator    text,                               -- 经手管理员（登录邮箱）
  created_at  timestamptz not null default now()
);

-- ---------- 索引 ----------
create index if not exists idx_meal_cards_member  on public.meal_cards (member_id, status);
create index if not exists idx_card_usages_card   on public.card_usages (card_id);
create index if not exists idx_card_usages_member on public.card_usages (member_id);
create index if not exists idx_card_usages_date   on public.card_usages (used_date);
create index if not exists idx_cash_logs_date     on public.cash_logs (log_date);

-- ============================================================
-- 安全策略（RLS）：只有登录的管理员账号才能读写任何数据。
-- 没登录的人即使拿到网址和公开密钥，也一行数据都读不到。
-- ============================================================
alter table public.members     enable row level security;
alter table public.meal_cards  enable row level security;
alter table public.card_usages enable row level security;
alter table public.cash_logs   enable row level security;

drop policy if exists "admins_all_members"     on public.members;
drop policy if exists "admins_all_meal_cards"  on public.meal_cards;
drop policy if exists "admins_all_card_usages" on public.card_usages;
drop policy if exists "admins_all_cash_logs"   on public.cash_logs;

create policy "admins_all_members"     on public.members     for all to authenticated using (true) with check (true);
create policy "admins_all_meal_cards"  on public.meal_cards  for all to authenticated using (true) with check (true);
create policy "admins_all_card_usages" on public.card_usages for all to authenticated using (true) with check (true);
create policy "admins_all_cash_logs"   on public.cash_logs   for all to authenticated using (true) with check (true);

-- ============================================================
-- 实时同步：让两台手机上的页面能立刻看到对方的操作
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['members','meal_cards','card_usages','cash_logs'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ============================================================
-- 以下规则与 migration.sql 完全相同（由它自动生成，两边永远一致）
-- ============================================================

-- ---------- 1. 去掉「同一人同一天只能用一次」的限制 ----------
alter table public.card_usages drop constraint if exists card_usages_one_per_day;

-- ---------- 2. 成员增加「小组」字段 ----------
alter table public.members add column if not exists group_name text not null default '';
create index if not exists idx_members_group on public.members (group_name);

-- ---------- 3. 收款时间 ----------
alter table public.meal_cards add column if not exists paid_at timestamptz;
-- 以前的已付卡没有记录收款时间，只能按开卡时间算
update public.meal_cards set paid_at = created_at where is_paid and paid_at is null;

-- ---------- 6. 日期默认按巴塞罗那时间 ----------
alter table public.card_usages alter column used_date set default ((now() at time zone 'Europe/Madrid')::date);
alter table public.cash_logs   alter column log_date  set default ((now() at time zone 'Europe/Madrid')::date);

-- ---------- 0. 谁做的（第 8 版）：「现在是谁」，饭卡上「谁开的卡」「谁收的钱」（下面 4a 的规则要用，所以放最前面）----------
-- 登录账号自己填的名字（小组长第一次登录时填）后面带上账号，比如「李明（liming）」：名字是自己填的，
-- 账号是管理员在 Supabase 里建的，谁也冒充不了谁。没填名字就只写账号（共用账号就是 admin）；
-- 在 Supabase 后台直接改的，记成「数据库后台」
create or replace function public.mealcard_actor() returns text
language sql stable set search_path = '' as $$
  select case when u = '' then '数据库后台'
              when n = '' or n = u then u
              else left(n, 20) || '（' || u || '）' end
    from (select btrim(coalesce(c -> 'user_metadata' ->> 'name', '')) as n,
                 left(split_part(coalesce(c ->> 'email', ''), '@', 1), 30) as u
            from (select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb as c) x) y
$$;
grant execute on function public.mealcard_actor() to authenticated;
alter table public.meal_cards  add column if not exists created_by text;   -- 谁开的卡
alter table public.meal_cards  add column if not exists paid_by    text;   -- 谁收的 20 欧（标记已付的人）

-- ---------- 4a. 饭卡：新开卡 / 改收款状态 ----------
create or replace function public.mealcard_card_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    -- 锁住这个成员，两台手机同时给同一个人开卡时排队执行
    perform 1 from public.members where id = new.member_id for update;
    if coalesce(new.status, 'ACTIVE') = 'ACTIVE' and exists (
         select 1 from public.meal_cards where member_id = new.member_id and status = 'ACTIVE') then
      raise exception 'member_has_active_card' using errcode = 'P0001',
        hint = '这个人已经有一张使用中的饭卡';
    end if;
    if new.is_paid and new.paid_at is null then new.paid_at := now(); end if;
    if new.is_paid then new.paid_by := public.mealcard_actor();              -- 谁收的 20 欧
    else new.paid_at := null; new.paid_by := null; end if;
  elsif tg_op = 'UPDATE' then
    if new.is_paid and not old.is_paid then new.paid_at := now(); new.paid_by := public.mealcard_actor();
    elsif not new.is_paid then new.paid_at := null; new.paid_by := null;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists mealcard_card_guard on public.meal_cards;
create trigger mealcard_card_guard before insert or update of is_paid on public.meal_cards
  for each row execute function public.mealcard_card_guard();

-- ---------- 4b. 打卡：最多 5 次，作废的卡不能打 ----------
create or replace function public.mealcard_usage_guard() returns trigger
language plpgsql set search_path = '' as $$
declare c record; n int;
begin
  -- 锁住这张卡，两台手机同时打最后一次时排队，后到的会被拦下
  select id, member_id, status into c from public.meal_cards where id = new.card_id for update;
  if not found then
    raise exception 'card_not_found' using errcode = 'P0001';
  end if;
  if c.status = 'ARCHIVED' then
    raise exception 'card_archived' using errcode = 'P0001', hint = '这张卡已经作废';
  end if;
  select count(*) into n from public.card_usages where card_id = new.card_id;
  if n >= 5 then
    raise exception 'card_full' using errcode = 'P0001', hint = '这张卡 5 次已经用完';
  end if;
  new.member_id := c.member_id;
  if new.used_date is null then new.used_date := (now() at time zone 'Europe/Madrid')::date; end if;
  return new;
end $$;

drop trigger if exists mealcard_usage_guard on public.card_usages;
create trigger mealcard_usage_guard before insert on public.card_usages
  for each row execute function public.mealcard_usage_guard();

-- ---------- 4c. 打卡/撤销后，卡的状态自动跟着次数走 ----------
create or replace function public.mealcard_usage_sync_status() returns trigger
language plpgsql set search_path = '' as $$
declare cid uuid := coalesce(new.card_id, old.card_id); c record; n int;
begin
  select id, member_id, status into c from public.meal_cards where id = cid for update;
  if not found or c.status = 'ARCHIVED' then return null; end if;
  select count(*) into n from public.card_usages where card_id = cid;
  if n >= 5 and c.status <> 'EXHAUSTED' then
    update public.meal_cards set status = 'EXHAUSTED' where id = cid;
  elsif n < 5 and c.status = 'EXHAUSTED'
        and not exists (select 1 from public.meal_cards
                        where member_id = c.member_id and status = 'ACTIVE' and id <> cid) then
    update public.meal_cards set status = 'ACTIVE' where id = cid;
  end if;
  return null;
end $$;

drop trigger if exists mealcard_usage_sync_status on public.card_usages;
create trigger mealcard_usage_sync_status after insert or delete on public.card_usages
  for each row execute function public.mealcard_usage_sync_status();

-- ---------- 5. 开卡（可选同时作废旧卡），一步完成 ----------
create or replace function public.mealcard_issue_card(p_member uuid, p_paid boolean, p_replace uuid default null)
returns public.meal_cards
language plpgsql set search_path = '' as $$
declare r public.meal_cards;
begin
  -- 先锁这个人（先人后卡，和打卡、删除人的顺序一样）：同一瞬间另一台在旧卡上打卡，会排在开卡之前或之后，不会互相卡住
  perform 1 from public.members where id = p_member for update;
  if p_replace is not null then
    update public.meal_cards set status = 'ARCHIVED'
     where id = p_replace and member_id = p_member and status = 'ACTIVE';
  end if;
  insert into public.meal_cards(member_id, is_paid) values (p_member, p_paid) returning * into r;
  return r;
end $$;
revoke all on function public.mealcard_issue_card(uuid, boolean, uuid) from public, anon;
grant execute on function public.mealcard_issue_card(uuid, boolean, uuid) to authenticated;

-- 网页据此判断数据库有没有升级到这一版
-- ---------- 8a. 打卡：几台手机同时给同一张卡打卡时排队，当天第二次起必须确认 ----------
create or replace function public.mealcard_punch(p_id uuid, p_card uuid, p_repeat boolean default false)
returns public.card_usages
language plpgsql set search_path = '' as $$
declare r public.card_usages; c record; n int;
  today date := (now() at time zone 'Europe/Madrid')::date;
begin
  -- 先锁这个人，再锁卡：和删除人、开卡、签到的顺序一样（先人后卡），一台删人、一台同时打卡时不会互相卡住（死锁）。
  -- 用最轻的锁：同一个人同时打卡、签到、改名都不用排队，只有删除这个人、给他开卡时才等一下
  perform 1 from public.members where id = (select member_id from public.meal_cards where id = p_card) for key share;
  -- 锁住这张卡：同时给同一张卡打卡的手机在这里排队，后到的能看到先到的那一次
  select id, member_id, status into c from public.meal_cards where id = p_card for update;
  if not found then raise exception 'card_not_found' using errcode = 'P0001'; end if;
  -- 同一条记录重发（网络差时手机会自动重试）：已经存上了就直接返回，不会记两次
  select * into r from public.card_usages where id = p_id;
  if found then return r; end if;
  if c.status = 'ARCHIVED' then
    raise exception 'card_archived' using errcode = 'P0001', hint = '这张卡已经作废';
  end if;
  select count(*) into n from public.card_usages where card_id = p_card;
  if n >= 5 then
    raise exception 'card_full' using errcode = 'P0001', hint = '这张卡 5 次已经用完';
  end if;
  -- 今天已经用过（可能是另一台手机刚打的）：要有人点了「再用一次」才能再扣
  if not coalesce(p_repeat, false) and exists (
       select 1 from public.card_usages where card_id = p_card and used_date = today) then
    raise exception 'already_used_today' using errcode = 'P0001', hint = '这张卡今天已经用过了';
  end if;
  insert into public.card_usages(id, card_id, member_id) values (p_id, p_card, c.member_id)
  returning * into r;
  return r;
end $$;
revoke all on function public.mealcard_punch(uuid, uuid, boolean) from public, anon;
grant execute on function public.mealcard_punch(uuid, uuid, boolean) to authenticated;

-- ---------- 8b. 添加成员：两台手机同时加同一个名字，只会加成一个 ----------
create or replace function public.mealcard_add_member(p_id uuid, p_name text, p_pinyin text default '',
                                                      p_group text default '', p_allow_dup boolean default false)
returns public.members
language plpgsql set search_path = '' as $$
declare r public.members;
begin
  -- 按名字排队：同一个名字同时只有一台手机在加
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('mealcard_member:' || p_name));
  select * into r from public.members where id = p_id;
  if found then return r; end if;
  if not coalesce(p_allow_dup, false) and exists (select 1 from public.members where name = p_name) then
    raise exception 'member_name_exists' using errcode = 'P0001', hint = '名册里已经有同名的人';
  end if;
  insert into public.members(id, name, pinyin, group_name)
  values (p_id, p_name, coalesce(p_pinyin, ''), coalesce(p_group, ''))
  returning * into r;
  return r;
end $$;
revoke all on function public.mealcard_add_member(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.mealcard_add_member(uuid, text, text, text, boolean) to authenticated;

-- ---------- 8c. 撤销打卡：另一台手机刚给这个人换了新卡时，旧卡上的记录不能再撤销 ----------
-- （不然旧卡会少一次、却因为已经有新卡而一直算「已用完」，那一顿就白白作废了）
create or replace function public.mealcard_revoke(p_id uuid)
returns void
language plpgsql set search_path = '' as $$
declare u record; c record;
begin
  select id, card_id, member_id into u from public.card_usages where id = p_id;
  if not found then return; end if;                -- 已经撤销过了（可能另一台手机刚撤销）：什么都不用做
  -- 先锁这个人，再锁卡（和打卡、开卡、删除人的顺序一样）：另一台手机同一瞬间给他开新卡时两边排队，
  -- 不会出现「旧卡撤销后变回使用中，同时又开了一张新卡」—— 一个人两张使用中的卡
  perform 1 from public.members where id = u.member_id for key share;
  select id, member_id, status, created_at into c from public.meal_cards where id = u.card_id for update;
  if not found then return; end if;                -- 这个人（连同卡）刚被删掉了
  if c.status = 'ARCHIVED' then
    raise exception 'card_archived' using errcode = 'P0001', hint = '这张卡已经作废';
  end if;
  if c.status = 'EXHAUSTED' and exists (
       select 1 from public.meal_cards o
        where o.member_id = c.member_id and o.id <> c.id
          and o.status <> 'ARCHIVED' and o.created_at > c.created_at) then
    raise exception 'card_replaced' using errcode = 'P0001', hint = '这张卡已经换了新卡';
  end if;
  delete from public.card_usages where id = p_id;
end $$;
revoke all on function public.mealcard_revoke(uuid) from public, anon;
grant execute on function public.mealcard_revoke(uuid) to authenticated;

-- ---------- 9. 支出登记（有特别需要时额外花的钱）----------
create table if not exists public.expenses (
  id          uuid          primary key default gen_random_uuid(),
  spent_date  date          not null default ((now() at time zone 'Europe/Madrid')::date),
  amount      numeric(10,2) not null check (amount > 0 and amount < 100000),   -- 花了多少欧
  purpose     text          not null default '' check (char_length(purpose) <= 200),   -- 用途
  handler     text          not null default '' check (char_length(handler) <= 50),    -- 经手人（谁付的钱），选填
  operator    text,                                                                  -- 登记用的账号
  created_at  timestamptz   not null default now()
);
create index if not exists idx_expenses_date on public.expenses (spent_date);
alter table public.expenses enable row level security;
drop policy if exists "admins_all_expenses" on public.expenses;
create policy "admins_all_expenses" on public.expenses for all to authenticated using (true) with check (true);
do $$ begin
  alter publication supabase_realtime add table public.expenses;
exception when duplicate_object then null;
end $$;

-- ---------- 10. 签到（每周聚会：✓ 准时到、迟到、✗ 缺席）----------
create table if not exists public.attendance (
  id          uuid        primary key default gen_random_uuid(),
  member_id   uuid        not null references public.members(id) on delete cascade,
  att_date    date        not null default ((now() at time zone 'Europe/Madrid')::date),  -- 哪一次聚会（巴塞罗那的日期）
  status      text        not null check (status in ('present', 'late', 'absent')),       -- 准时到 / 迟到 / 缺席
  arrived_at  timestamptz,                    -- 当场点「签到」的时间（事后补记的、缺席的没有）
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint attendance_one_per_day unique (member_id, att_date)   -- 一个人一次聚会只有一条记录
);
create index if not exists idx_attendance_date on public.attendance (att_date);
alter table public.attendance enable row level security;
drop policy if exists "admins_all_attendance" on public.attendance;
create policy "admins_all_attendance" on public.attendance for all to authenticated using (true) with check (true);
do $$ begin
  alter publication supabase_realtime add table public.attendance;
exception when duplicate_object then null;
end $$;

-- ---------- 11. 设置：几点以后签到算「迟」（几台手机共用一份）----------
create table if not exists public.app_settings (
  id          text        primary key,
  value       text        not null,
  updated_at  timestamptz not null default now(),
  constraint app_settings_late_after check (id <> 'late_after' or value ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')
);
insert into public.app_settings (id, value) values ('late_after', '13:40') on conflict (id) do nothing;
alter table public.app_settings enable row level security;
drop policy if exists "admins_all_app_settings" on public.app_settings;
create policy "admins_all_app_settings" on public.app_settings for all to authenticated using (true) with check (true);
do $$ begin
  alter publication supabase_realtime add table public.app_settings;
exception when duplicate_object then null;
end $$;

-- ---------- 10a. 签到 / 改签到状态 ----------
-- p_status 为空 = 当场点「签到」：按服务器的巴塞罗那时间判断准时还是迟到（不看手机自己的时钟）；
--   已经签过到的人保留第一次的时间（两台手机同时给同一个人签到，只算先到的那次）；
--   之前被记了缺席、后来人到了，改成到了。
-- p_status = present / late / absent：手动改成准时 / 迟到 / 缺席。
create or replace function public.mealcard_checkin(p_id uuid, p_member uuid, p_date date, p_status text default null)
returns public.attendance
language plpgsql set search_path = '' as $$
declare
  r public.attendance;
  today date := (now() at time zone 'Europe/Madrid')::date;
  late_after time;
  st text;
begin
  if p_status is not null and p_status not in ('present', 'late', 'absent') then
    raise exception 'bad_status' using errcode = 'P0001';
  end if;
  if p_date is null or p_date > today then
    raise exception 'bad_date' using errcode = 'P0001', hint = '不能给还没到的日子签到';
  end if;
  -- 先锁住这个人：同一个人的签到排队处理；删除这个人也是先锁人，顺序一致就不会互相卡住
  perform 1 from public.members where id = p_member for no key update;
  if not found then
    raise exception 'member_not_found' using errcode = 'P0001', hint = '这个人刚被删除了';
  end if;
  if p_status is null then
    select value::time into late_after from public.app_settings where id = 'late_after';
    st := case when p_date = today
                and (now() at time zone 'Europe/Madrid')::time >= coalesce(late_after, '13:40'::time)
               then 'late' else 'present' end;
    -- 没有记录：新记一条；之前记了缺席（包括另一台手机正在「记为缺席」）：改成到了；
    -- 已经签过到的：一个字都不改，保留第一次的时间
    insert into public.attendance (id, member_id, att_date, status, arrived_at)
    values (coalesce(p_id, gen_random_uuid()), p_member, p_date, st, case when p_date = today then now() end)
    on conflict (member_id, att_date) do update
       set status = excluded.status, arrived_at = excluded.arrived_at, updated_at = now()
     where public.attendance.status = 'absent'
    returning * into r;
    if not found then
      select * into r from public.attendance where member_id = p_member and att_date = p_date;
    end if;
  else
    insert into public.attendance (id, member_id, att_date, status)
    values (coalesce(p_id, gen_random_uuid()), p_member, p_date, p_status)
    on conflict (member_id, att_date) do update
       set status = excluded.status, updated_at = now(),
           arrived_at = case when excluded.status = 'absent' then null else public.attendance.arrived_at end
    returning * into r;
  end if;
  return r;
end $$;
revoke all on function public.mealcard_checkin(uuid, uuid, date, text) from public, anon;
grant execute on function public.mealcard_checkin(uuid, uuid, date, text) to authenticated;

-- ---------- 10b. 补签 / 修改签到：改日期、改几点到的、准时还是迟到 ----------
-- p_time：几点到的（'13:32'，巴塞罗那时间；不知道就传空）。不能晚于现在（手机的钟快几分钟的，按现在记）。
-- p_from_date：要把这条签到从哪一天挪过来（改日期时用；补签新的就传空）。
-- 同一个人目标那天已经有记录的，用这次的覆盖。
create or replace function public.mealcard_set_attendance(p_member uuid, p_date date, p_status text,
                                                          p_time text default null, p_from_date date default null)
returns public.attendance
language plpgsql set search_path = '' as $$
declare
  r public.attendance;
  today date := (now() at time zone 'Europe/Madrid')::date;
  arr timestamptz;
begin
  if p_status is null or p_status not in ('present', 'late') then
    raise exception 'bad_status' using errcode = 'P0001';
  end if;
  if p_date is null or p_date > today or (p_from_date is not null and p_from_date > today) then
    raise exception 'bad_date' using errcode = 'P0001', hint = '不能给还没到的日子签到';
  end if;
  if p_time is not null and p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'bad_time' using errcode = 'P0001', hint = '时间要写成 13:32 这样';
  end if;
  arr := case when p_time is null then null else ((p_date + p_time::time) at time zone 'Europe/Madrid') end;
  if arr is not null and arr > now() then
    -- 比现在还晚：手机的钟快了几分钟的，按服务器的「现在」记；晚得多的（填错了）不收
    if arr > now() + interval '10 minutes' then
      raise exception 'future_time' using errcode = 'P0001', hint = '签到时间不能晚于现在';
    end if;
    arr := now();
  end if;
  -- 先锁住这个人（和「签到」「删除这个人」的顺序一致，不会互相卡住）
  perform 1 from public.members where id = p_member for no key update;
  if not found then
    raise exception 'member_not_found' using errcode = 'P0001', hint = '这个人刚被删除了';
  end if;
  insert into public.attendance (member_id, att_date, status, arrived_at)
  values (p_member, p_date, p_status, arr)
  on conflict (member_id, att_date) do update
     set status = excluded.status, arrived_at = excluded.arrived_at, updated_at = now()
  returning * into r;
  if p_from_date is not null and p_from_date <> p_date then
    delete from public.attendance where member_id = p_member and att_date = p_from_date;
  end if;
  return r;
end $$;
revoke all on function public.mealcard_set_attendance(uuid, date, text, text, date) from public, anon;
grant execute on function public.mealcard_set_attendance(uuid, date, text, text, date) to authenticated;

-- 第 6 版的「把还没签到的人一次记为缺席」不用了：周日过去以后，没签到的人自动算缺席
drop function if exists public.mealcard_mark_absent(date, uuid[]);

-- ---------- 13. 谁做的：每一次改动都自动记下来（修改记录），各条记录上也写着是谁记的 ----------
-- 13b. 各条记录上「谁记的」（以前的记录是空的；饭卡上的两栏在最前面「0.」里已经加好）
alter table public.members     add column if not exists created_by text;   -- 谁加进名册的
alter table public.card_usages add column if not exists created_by text;   -- 谁打的卡
alter table public.cash_logs   add column if not exists created_by text;   -- 谁记的散客
alter table public.expenses    add column if not exists created_by text;   -- 谁记的支出
alter table public.attendance  add column if not exists created_by text;   -- 谁签的到
alter table public.attendance  add column if not exists updated_by text;   -- 最后谁改的

-- 由数据库自己填，网页填什么都不算（谁也冒充不了别人）
create or replace function public.mealcard_stamp_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.created_by := public.mealcard_actor();
  return new;
end $$;
create or replace function public.mealcard_stamp_insert_att() returns trigger  -- 签到新记录：还没人改过
language plpgsql set search_path = '' as $$
begin
  new.created_by := public.mealcard_actor();
  new.updated_by := null;
  return new;
end $$;
create or replace function public.mealcard_stamp_update() returns trigger      -- 签到：记下最后是谁改的
language plpgsql set search_path = '' as $$
begin
  new.created_by := old.created_by;
  new.updated_by := public.mealcard_actor();
  return new;
end $$;
create or replace function public.mealcard_keep_creator() returns trigger      -- 改别的地方时，「谁记的」保持不变
language plpgsql set search_path = '' as $$
begin
  new.created_by := old.created_by;
  return new;
end $$;
create or replace function public.mealcard_card_keep() returns trigger         -- 饭卡：「谁开的」不变；「谁收的钱」只在改收款时变
language plpgsql set search_path = '' as $$
begin
  new.created_by := old.created_by;
  if new.is_paid is not distinct from old.is_paid then new.paid_by := old.paid_by; end if;
  return new;
end $$;

-- 13c. 修改记录：谁、什么时候、改了哪一条、改之前和改之后是什么样。
--      只有数据库自己能往里写；网页只能看，改不了也删不了
create table if not exists public.change_log (
  id          bigint      generated always as identity primary key,
  at          timestamptz not null default now(),
  tx          bigint      not null default txid_current(),   -- 同一次操作（比如删人连带删卡）是同一个号
  actor       text        not null,                          -- 谁（当时的名字）
  actor_email text,                                          -- 用的哪个登录账号
  tbl         text        not null,                          -- 哪张表
  op          text        not null,                          -- INSERT 新加 / UPDATE 修改 / DELETE 删除
  row_id      text,
  member_id   uuid,                                          -- 跟哪个人有关（方便按人查）
  old_data    jsonb,
  new_data    jsonb
);
create index if not exists idx_change_log_member on public.change_log (member_id, id desc);
alter table public.change_log enable row level security;
drop policy if exists "admins_read_change_log" on public.change_log;
create policy "admins_read_change_log" on public.change_log for select to authenticated using (true);
revoke all on public.change_log from public, anon;
revoke insert, update, delete, truncate on public.change_log from authenticated;
grant select on public.change_log to authenticated;

create or replace function public.mealcard_log() returns trigger
language plpgsql security definer set search_path = '' as $$
declare o jsonb; n jsonb; c jsonb;
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;            -- 什么都没变，不记
  c := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  insert into public.change_log (actor, actor_email, tbl, op, row_id, member_id, old_data, new_data)
  values (public.mealcard_actor(), c ->> 'email', tg_table_name, tg_op,
          coalesce(n, o) ->> 'id',
          case when tg_table_name = 'members' then (coalesce(n, o) ->> 'id')::uuid
               else (coalesce(n, o) ->> 'member_id')::uuid end,
          o, n);
  return null;
end $$;
revoke all on function public.mealcard_log() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['members', 'meal_cards', 'card_usages', 'cash_logs', 'expenses', 'attendance', 'app_settings'] loop
    execute format('drop trigger if exists mealcard_log on public.%I', t);
    execute format('create trigger mealcard_log after insert or update or delete on public.%I for each row execute function public.mealcard_log()', t);
  end loop;
  foreach t in array array['members', 'meal_cards', 'card_usages', 'cash_logs', 'expenses'] loop
    execute format('drop trigger if exists mealcard_stamp on public.%I', t);
    execute format('create trigger mealcard_stamp before insert on public.%I for each row execute function public.mealcard_stamp_insert()', t);
  end loop;
end $$;
drop trigger if exists mealcard_stamp on public.attendance;
create trigger mealcard_stamp before insert on public.attendance for each row execute function public.mealcard_stamp_insert_att();
do $$ declare t text; begin
  foreach t in array array['members', 'card_usages', 'cash_logs', 'expenses'] loop
    execute format('drop trigger if exists mealcard_stamp_upd on public.%I', t);
    execute format('create trigger mealcard_stamp_upd before update on public.%I for each row execute function public.mealcard_keep_creator()', t);
  end loop;
end $$;
drop trigger if exists mealcard_stamp_upd on public.meal_cards;
create trigger mealcard_stamp_upd before update on public.meal_cards for each row execute function public.mealcard_card_keep();
drop trigger if exists mealcard_stamp_upd on public.attendance;
create trigger mealcard_stamp_upd before update on public.attendance for each row execute function public.mealcard_stamp_update();

create or replace function public.mealcard_schema_version() returns int
language sql stable set search_path = '' as $$ select 8 $$;
grant execute on function public.mealcard_schema_version() to anon, authenticated;

-- ---------- 7. 修正历史数据 ----------
update public.meal_cards c set status = 'EXHAUSTED'
 where c.status = 'ACTIVE'
   and (select count(*) from public.card_usages u where u.card_id = c.id) >= 5;

-- ---------- 8d. 保险：一个人同一时间最多一张「使用中」的卡（数据库硬规定，不管从哪条路改都拦得住）----------
-- 万一以前已经因为同时操作留下了两张使用中的卡，先不加这条（不影响升级；上面 8c 的排队已经保证以后不会再出现）
do $$ begin
  if not exists (select 1 from public.meal_cards where status = 'ACTIVE' group by member_id having count(*) > 1) then
    create unique index if not exists meal_cards_one_active on public.meal_cards (member_id) where status = 'ACTIVE';
  else
    raise notice '有人同时有两张使用中的饭卡，先不加「一人一张」的硬规定：%',
      (select string_agg(m.name, '、') from public.members m
        where (select count(*) from public.meal_cards c where c.member_id = m.id and c.status = 'ACTIVE') > 1);
  end if;
end $$;

-- 让接口层立刻识别新函数
notify pgrst, 'reload schema';

-- ============================================================
-- 检查结果：最后这一句应返回 8（表示升级完成）
-- ============================================================
select public.mealcard_schema_version() as 数据库版本;
