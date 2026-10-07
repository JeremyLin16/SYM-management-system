/* ============================================================
   把下面两行引号里的内容，换成你自己 Supabase 项目的地址和公开密钥。
   在 Supabase 后台 → Project Settings → API 里可以找到：
     SUPABASE_URL      = 那里的 "Project URL"
     SUPABASE_ANON_KEY = 那里的 "anon public" 密钥（很长的一串）

   这个 anon 公开密钥本来就是设计成可以公开放在网页里的，
   真正的保护来自 schema.sql 里设置的登录策略（没登录就一行数据都读不到）。
   千万不要把标着 "service_role" 的那个密钥放进来。
   ============================================================ */

window.MEALCARD_CONFIG = {
  SUPABASE_URL: "https://rodtgpeipikpxnvfqtju.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_9f67Yq5gDqHY12Hj557zPg_zPcz3PrG",
  // 共用账号：Supabase → Authentication → Users 里建的那个共用账号的「邮箱」。
  // 它不用是真的邮箱，也不会收到任何邮件，只要跟 Supabase 里建的一模一样就行。
  // 大家登录时只输密码。
  SHARED_ACCOUNT: "admin@star-mealcard.pages.dev"
};
