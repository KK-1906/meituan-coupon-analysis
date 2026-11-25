-- =====================================================================
-- 美团优惠券投放提效分析 · 核心 SQL（DuckDB 方言，可完整复现）
-- 数据：order_detail.csv / user_coupon_receive.csv / user_visit_detail.csv
-- 口径：①GMV=订单级实付(Actual_pay)；②多券订单 GMV 按券数均分归因；
--       ③券成本=核销券面额(保守)；④券型分析只覆盖"有效券"。
-- =====================================================================

-- 0. 载入原始数据（只读，不修改源文件）
CREATE OR REPLACE VIEW order_raw AS
SELECT * FROM read_csv_auto('D:/大学/数据分析/order_detail.csv', header = true, sample_size = 200000);

CREATE OR REPLACE VIEW coupon_raw AS
SELECT * FROM read_csv_auto('D:/大学/数据分析/user_coupon_receive.csv', header = true, sample_size = 200000);

CREATE OR REPLACE VIEW visit_raw AS
SELECT * FROM read_csv_auto('D:/大学/数据分析/user_visit_detail.csv', header = true, sample_size = 200000);

-- ---------------------------------------------------------------------
-- 1. 订单去重：同一 Order_id 多行 = 一单叠加多张券
--    实付取 MAX，补贴求和；行级汇总会把 GMV 高估 52.5%
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE orders AS
SELECT
    Order_id,
    any_value(User_id)                                    AS User_id,
    any_value(Shop_id)                                    AS Shop_id,
    any_value(Pay_date)                                   AS Pay_date,
    any_value(Biz_code)                                   AS Biz_code,
    MAX(Actual_pay)                                       AS gmv,      -- 实付金额
    SUM(Reduce_amount)                                    AS subsidy,
    COUNT(DISTINCT CASE WHEN Coupon_id <> 'NULL' THEN Coupon_id END) AS coupon_cnt,
    MAX(CASE WHEN Coupon_id <> 'NULL' THEN 1 ELSE 0 END)  AS has_coupon,
    COUNT(*)                                              AS line_cnt
FROM order_raw
GROUP BY Order_id;

-- 校验：行级 vs 订单级
SELECT SUM(Actual_pay) AS gmv_row_level FROM order_raw;      -- 60,061,172
SELECT SUM(gmv)        AS gmv_order_level FROM orders;       -- 39,389,606

-- ---------------------------------------------------------------------
-- 2. 券清洗 + 核销标记（used 字段在此定义）
--    Coupon_id 全局唯一（0 重复），可作券实例 ID
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE coupon_used AS
SELECT o.Coupon_id, MIN(o.Pay_date) AS use_date
FROM order_raw o WHERE o.Coupon_id <> 'NULL' GROUP BY o.Coupon_id;

CREATE OR REPLACE TABLE coupon_fact AS
SELECT
    c.User_id, c.Coupon_id,
    CAST(c.Coupon_status AS INTEGER)                AS status,
    try_cast(c.Coupon_amt    AS DOUBLE)             AS face_amt,
    try_cast(c.Price_limit   AS DOUBLE)             AS price_limit,
    try_cast(c.Receive_date  AS DATE)               AS receive_date,
    date_diff('day', try_cast(c.Start_date AS DATE),
                     try_cast(c.End_date   AS DATE)) AS valid_days,
    CASE WHEN u.Coupon_id IS NOT NULL THEN 1 ELSE 0 END AS used,
    u.use_date
FROM coupon_raw c LEFT JOIN coupon_used u USING (Coupon_id)
WHERE try_cast(c.Coupon_amt   AS DOUBLE) IS NOT NULL
  AND try_cast(c.Receive_date AS DATE)   IS NOT NULL;

-- 有效券口径：剔除倒挂（面额>=门槛）与极端面额
CREATE OR REPLACE TABLE coupon_ok AS
SELECT * FROM coupon_fact
WHERE (price_limit = 0 OR face_amt < price_limit)
  AND face_amt <= 500;

-- ---------------------------------------------------------------------
-- 3. 维度 GMV 均分归因：订单级实付按券数均分到每张 used 券
--    避免多券订单重复归因（逐券直接 SUM 会多计 14.0%）
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE coupon_gmv_attr AS
SELECT m.Coupon_id, ROUND(SUM(o.gmv * 1.0 / m.n), 2) AS gmv_attr
FROM (
    SELECT Order_id, Coupon_id, COUNT(*) OVER (PARTITION BY Order_id) AS n
    FROM (SELECT DISTINCT Order_id, Coupon_id
          FROM order_raw WHERE Coupon_id <> 'NULL') x
) m
JOIN orders o USING (Order_id)
WHERE o.has_coupon = 1
GROUP BY m.Coupon_id;

-- 口径自洽检查：均分合计 = 订单级券实付；有效券部分 + 被剔除券部分 = 全部
SELECT
    (SELECT SUM(gmv) FROM orders WHERE has_coupon = 1)                    AS order_coupon_gmv,
    (SELECT SUM(gmv_attr) FROM coupon_gmv_attr)                          AS attr_total,
    (SELECT SUM(g.gmv_attr) FROM coupon_ok c JOIN coupon_gmv_attr g USING(Coupon_id) WHERE c.used=1) AS valid_coupon_gmv;

-- ---------------------------------------------------------------------
-- 4. 大盘：月度实付 / 订单 / 客单 / 券渗透
-- ---------------------------------------------------------------------
SELECT strftime(Pay_date, '%Y-%m')           AS mon,
       COUNT(*)                              AS orders,
       COUNT(DISTINCT User_id)               AS buyers,
       ROUND(SUM(gmv), 1)                    AS gmv,
       ROUND(AVG(gmv), 2)                    AS aov,
       ROUND(SUM(has_coupon) * 1.0 / COUNT(*), 4) AS coupon_order_share,
       ROUND(SUM(subsidy) / SUM(gmv), 4)     AS subsidy_rate
FROM orders GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 5. 券设计维度效果（门槛/面额/有效期），GMV 用均分归因
--    成本 = 核销券面额（保守下界）；登记口径为 Reduce_amount（乐观上界）
-- ---------------------------------------------------------------------
SELECT CASE WHEN price_limit = 0 THEN '无门槛'
            WHEN price_limit <= 20 THEN '1-20元'
            WHEN price_limit <= 30 THEN '21-30元'
            WHEN price_limit <= 50 THEN '31-50元'
            WHEN price_limit <= 100 THEN '51-100元'
            ELSE '100元以上' END                     AS lim_b,
       COUNT(*)                                      AS issued,
       SUM(used)                                     AS used,
       ROUND(AVG(used), 4)                           AS cvr,
       ROUND(SUM(CASE WHEN used = 1 THEN face_amt ELSE 0 END), 0) AS cost,
       ROUND(SUM(g.gmv_attr), 0)                     AS coupon_gmv,
       ROUND(SUM(g.gmv_attr) / NULLIF(SUM(CASE WHEN used = 1 THEN face_amt ELSE 0 END), 0), 2) AS roi
FROM coupon_ok c LEFT JOIN coupon_gmv_attr g USING (Coupon_id)
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 6. RFM 五分位打分 + 完整八分群
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT User_id,
           date_diff('day', MAX(Pay_date), DATE '2023-06-30') AS R,
           COUNT(*) AS F, SUM(gmv) AS M
    FROM orders GROUP BY 1
),
scored AS (
    SELECT *,
        CASE WHEN cume_dist() OVER (ORDER BY R ASC)  <= 0.2 THEN 5
             WHEN cume_dist() OVER (ORDER BY R ASC)  <= 0.4 THEN 4
             WHEN cume_dist() OVER (ORDER BY R ASC)  <= 0.6 THEN 3
             WHEN cume_dist() OVER (ORDER BY R ASC)  <= 0.8 THEN 2 ELSE 1 END AS R_score,
        CASE WHEN cume_dist() OVER (ORDER BY F DESC) <= 0.2 THEN 5
             WHEN cume_dist() OVER (ORDER BY F DESC) <= 0.4 THEN 4
             WHEN cume_dist() OVER (ORDER BY F DESC) <= 0.6 THEN 3
             WHEN cume_dist() OVER (ORDER BY F DESC) <= 0.8 THEN 2 ELSE 1 END AS F_score,
        CASE WHEN cume_dist() OVER (ORDER BY M DESC) <= 0.2 THEN 5
             WHEN cume_dist() OVER (ORDER BY M DESC) <= 0.4 THEN 4
             WHEN cume_dist() OVER (ORDER BY M DESC) <= 0.6 THEN 3
             WHEN cume_dist() OVER (ORDER BY M DESC) <= 0.8 THEN 2 ELSE 1 END AS M_score
    FROM base
)
SELECT CASE
        WHEN R_score>=4 AND F_score>=4 AND M_score>=4 THEN '高价值用户'
        WHEN R_score>=4 AND F_score< 4 AND M_score< 4 THEN '新近低频低消费用户'
        WHEN R_score< 4 AND F_score>=4 AND M_score>=4 THEN '高价值流失风险用户'
        WHEN R_score>=4 AND F_score>=4 AND M_score< 4 THEN '高频低消费用户'
        WHEN R_score>=4 AND F_score< 4 AND M_score>=4 THEN '近期高消费低频用户'
        WHEN R_score< 4 AND F_score>=4 AND M_score< 4 THEN '历史高频低消费用户'
        WHEN R_score< 4 AND F_score< 4 AND M_score>=4 THEN '历史高消费低频用户'
        ELSE '低活跃低价值用户'
    END AS seg,
    COUNT(*) AS users, ROUND(AVG(M), 0) AS arpu
FROM scored GROUP BY 1 ORDER BY arpu DESC;

-- ---------------------------------------------------------------------
-- 7. 核销漏斗 + 过期率 / 未核销率 区分
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM coupon_ok)   AS issued,
    (SELECT SUM(used)  FROM coupon_ok) AS used,
    (SELECT COUNT(*) FROM orders WHERE has_coupon = 1) AS coupon_orders,
    ROUND((SELECT SUM(used)*1.0 FROM coupon_ok)
          / (SELECT COUNT(*) FROM coupon_ok), 4)              AS cvr,
    ROUND((SELECT AVG(CASE WHEN status = 3 THEN 1 ELSE 0 END)
           FROM coupon_ok), 4)                                AS expire_rate,   -- 状态字段口径
    ROUND(1 - (SELECT AVG(used) FROM coupon_ok), 4)           AS unused_rate;    -- 含尚未到期

-- ---------------------------------------------------------------------
-- 8. 增量测算：首次核销前后 30 天窗口（PSM-DiD 取数，完整实现见 work/04_increment.py）
-- ---------------------------------------------------------------------
WITH t0 AS (
    SELECT User_id, MIN(use_date) AS t0
    FROM coupon_fact WHERE used = 1 GROUP BY 1
)
SELECT o.User_id,
       SUM(CASE WHEN o.Pay_date <  t.t0 THEN o.gmv ELSE 0 END) AS pre_gmv,
       SUM(CASE WHEN o.Pay_date >= t.t0 THEN o.gmv ELSE 0 END) AS post_gmv
FROM orders o JOIN t0 t USING (User_id)
WHERE o.Pay_date BETWEEN t.t0 - INTERVAL 30 DAY
                     AND t.t0 + INTERVAL 29 DAY
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 9. 预算重分配情景模拟（无门槛券预算部分转移至 21-30 元门槛券，线性外推）
-- ---------------------------------------------------------------------
WITH pool AS (
    SELECT CASE WHEN price_limit = 0 THEN 'nm'
                WHEN price_limit BETWEEN 21 AND 30 THEN 'mid' END AS g,
           SUM(CASE WHEN used = 1 THEN face_amt ELSE 0 END) AS cost,
           SUM(g.gmv_attr) AS gmv
    FROM coupon_ok c LEFT JOIN coupon_gmv_attr g USING (Coupon_id)
    WHERE price_limit = 0 OR price_limit BETWEEN 21 AND 30
    GROUP BY 1
),
r AS (
    SELECT MAX(CASE WHEN g = 'nm'  THEN cost END)  AS nm_cost,
           MAX(CASE WHEN g = 'nm'  THEN gmv  END)  AS nm_gmv,
           MAX(CASE WHEN g = 'mid' THEN cost END)  AS mid_cost,
           MAX(CASE WHEN g = 'mid' THEN gmv  END)  AS mid_gmv,
           (SELECT SUM(gmv) FROM orders WHERE has_coupon = 1) AS total_gmv,
           (SELECT SUM(face_amt) FROM coupon_ok WHERE used = 1) AS total_cost
    FROM pool
)
SELECT
    ROUND(nm_cost * 0.3, 0) AS transfer_cost,
    ROUND(nm_cost * 0.3 * (mid_gmv/mid_cost - nm_gmv/nm_cost), 0) AS inc_gmv,
    ROUND((total_gmv + nm_cost * 0.3 * (mid_gmv/mid_cost - nm_gmv/nm_cost)) / total_cost, 2) AS new_roi
FROM r;
