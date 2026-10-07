-- ============================================================
-- 清空测试数据
--
-- 用法：Supabase 后台 → SQL Editor → New query → 粘贴 → Run
--
-- ⚠️ 删除无法撤销。如果里面已经有真实记录，先去网页上导出存一份：
--    「财务」页「导出全部明细 (CSV)」，「签到」页「导出签到表 (CSV)」，再执行。
-- （请先跑过 migration.sql——修改记录是第 8 版才有的；现在最新就是第 8 版）
--
-- 下面有两种，**只跑其中一种**，把另一种整段删掉或不要选中。
-- 两种都会把「修改记录」一起清空（测试时点来点去的记录留着没用）。
-- ============================================================


-- 先确认已经升级过：还没升级的话，这里会停下来提示，下面一行都不会执行、什么都不会删
do $$ begin
  if to_regclass('public.change_log') is null then
    raise exception '数据库还没升级：请先跑 migration.sql（最后显示「数据库版本 = 8」），再跑这个清空脚本。这次什么都没有删。';
  end if;
end $$;


-- ============================================================
-- 【方案 A】全部清空，回到刚建好的状态
--   人员名单、饭卡、打卡记录、散客流水、支出、签到、修改记录 —— 全删
--   适合：测试期间乱加的人也要一起清掉，准备重新导入真实名单
-- ============================================================

delete from public.attendance;
delete from public.card_usages;
delete from public.meal_cards;
delete from public.cash_logs;
delete from public.expenses;
delete from public.members;
delete from public.change_log;   -- 放最后：上面删的时候也会记一笔，这里一起清掉


-- ============================================================
-- 【方案 B】只清记录，保留人员名单
--   饭卡、打卡记录、散客流水、支出、签到、修改记录 —— 全删
--   人员名单（含小组、拼音）—— 保留
--   适合：名单已经导入好了，只想把测试时乱点的打卡、收款和签到清掉
--
--   要用这个方案的话，把上面【方案 A】那 7 行删掉，
--   然后把下面 6 行前面的 -- 去掉。
-- ============================================================

-- delete from public.attendance;
-- delete from public.card_usages;
-- delete from public.meal_cards;
-- delete from public.cash_logs;
-- delete from public.expenses;
-- delete from public.change_log;


-- ============================================================
-- 跑完之后，下面这段会报出各张表还剩多少行，用来确认结果
-- （「迟到时间」这个设置不会被清掉）
-- ============================================================

select '人员 members'      as 表, count(*) as 剩余行数 from public.members
union all
select '饭卡 meal_cards',        count(*) from public.meal_cards
union all
select '打卡记录 card_usages',   count(*) from public.card_usages
union all
select '散客流水 cash_logs',     count(*) from public.cash_logs
union all
select '支出 expenses',          count(*) from public.expenses
union all
select '签到 attendance',        count(*) from public.attendance
union all
select '修改记录 change_log',    count(*) from public.change_log;

-- 方案 A 跑完：七行应该都是 0
-- 方案 B 跑完：只有「人员」不是 0，其余六行是 0
