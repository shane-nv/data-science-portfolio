/*
 * 電商分眾決策模擬系統 — 特徵工程（上漏斗：預測加車）
 * 平台：BigQuery ML / Dataform（SQLX）
 * 說明：從 GA4 巢狀事件流萃取用戶行為特徵，並以 MIN(add_to_cart) 為時間截斷點防止資料洩漏。
 * 來源：本檔案自專案報告轉錄整理；完整排版見專案資料夾內的原始 PDF。
 */

config {
  type: "table",
  schema: "ga4_ml_us",
  name: "ga4_features_cart",
  description: "GA4 用戶行為特徵表：預測加車專用",
  dependencies: ["user_identity"],
}

WITH Raw_Data AS (
  SELECT
    *,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'engagement_time_msec') AS engagement_time_msec
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND geo.country = 'United States'
),
User_Cutoff_Times AS (
  SELECT
    user_pseudo_id,
    MIN(CASE WHEN event_name = 'add_to_cart' THEN event_timestamp END) AS cutoff_timestamp
  FROM Raw_Data
  GROUP BY user_pseudo_id
),
Filtered_Events AS (
  SELECT e.*
  FROM Raw_Data AS e
  LEFT JOIN User_Cutoff_Times AS c
    ON e.user_pseudo_id = c.user_pseudo_id
  WHERE c.cutoff_timestamp IS NULL
    OR e.event_timestamp < c.cutoff_timestamp
    OR (e.event_timestamp = c.cutoff_timestamp AND e.event_name != 'add_to_cart')
),
Base_Users AS (
  SELECT
    user_pseudo_id,
    MAX(event_timestamp) AS last_interaction_timestamp,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_interaction_date,   -- 觀測窗口末日 (供 days_in_dataset / 頻率, 非 split)
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_interaction_date,  -- 觀測窗口首日
    COUNT(DISTINCT ga_session_id) AS historical_session_count,
    IF(COUNT(DISTINCT ga_session_id) > 1, 1, 0) AS is_returning_user,
    SUM(IFNULL(engagement_time_msec, 0)) / 1000 AS total_engaged_time_seconds,
    ROUND(SAFE_DIVIDE(SUM(IFNULL(engagement_time_msec, 0)) / 1000, COUNT(DISTINCT ga_session_id)), 2) AS avg_session_engaged_time_seconds,
    COUNTIF(event_name = 'view_item') AS view_item_count,
    COUNTIF(event_name = 'page_view') AS page_view_count
  FROM Filtered_Events
  GROUP BY user_pseudo_id
),
Add_to_cart_Labels AS (
  SELECT DISTINCT user_pseudo_id, 1 AS add_to_cart_label
  FROM Raw_Data
  WHERE event_name = 'add_to_cart'
),
Purchase_Revenue AS (
  SELECT
    user_pseudo_id,
    SUM(ecommerce.purchase_revenue_in_usd) AS actual_purchase_revenue
  FROM Raw_Data
  WHERE event_name = 'purchase'
  GROUP BY user_pseudo_id
),
View_Item_Features AS (
  SELECT
    user_pseudo_id,
    COUNT(DISTINCT item_details.item_category) AS unique_categories_viewed,
    AVG(IFNULL(item_details.price, 0)) AS avg_price_viewed
  FROM Filtered_Events, UNNEST(items) AS item_details
  WHERE event_name = 'view_item'
  GROUP BY user_pseudo_id
),
Item_Repetition_Stats AS (
  SELECT
    e.user_pseudo_id,
    IFNULL(item_details.item_id, item_details.item_name) AS item_identifier,
    COUNT(DISTINCT e.ga_session_id) AS item_view_sessions,
    COUNT(1) AS item_view_counts
  FROM Filtered_Events AS e, UNNEST(e.items) AS item_details
  WHERE e.event_name = 'view_item'
  GROUP BY e.user_pseudo_id, item_identifier
),
User_Maxrep AS (
  SELECT
    user_pseudo_id,
    MAX(item_view_sessions) AS max_item_rep_sessions,
    MAX(item_view_counts) AS max_item_rep_views
  FROM Item_Repetition_Stats
  GROUP BY user_pseudo_id
)

SELECT
  F.* EXCEPT(page_view_count, view_item_count),

  -- 身分屬性 (全歷史、確定性、與下層一致)
  ID.traffic_source,
  ID.device_category,
  IFNULL(VIF.unique_categories_viewed, 0) AS unique_categories_viewed,
  IFNULL(VIF.avg_price_viewed, 0) AS avg_price_viewed,
  IFNULL(UM.max_item_rep_sessions, 0) AS max_item_rep_sessions,
  IFNULL(UM.max_item_rep_views, 0) AS max_item_rep_views,

  -- 這裡依舊可以使用 F.view_item_count 進行計算
  SAFE_DIVIDE(IFNULL(UM.max_item_rep_views, 0), F.view_item_count) AS item_focus_ratio,

  LN(IFNULL(F.historical_session_count, 0) + 1) AS log_historical_session_count,
  LN(IFNULL(F.total_engaged_time_seconds, 0) + 1) AS log_total_engaged_time_seconds,
  LN(IFNULL(F.avg_session_engaged_time_seconds, 0) + 1) AS log_avg_session_engaged_time_seconds,
  LN(IFNULL(VIF.unique_categories_viewed, 0) + 1) AS log_unique_categories_viewed,
  LN(IFNULL(VIF.avg_price_viewed, 0) + 1) AS log_avg_price_viewed,
  LN(IFNULL(UM.max_item_rep_sessions, 0) + 1) AS log_max_item_rep_sessions,
  LN(IFNULL(UM.max_item_rep_views, 0) + 1) AS log_max_item_rep_views,

  -- 觀測窗口跨度與頻率
  DATE_DIFF(F.last_interaction_date, F.first_interaction_date, DAY) AS days_in_dataset,
  SAFE_DIVIDE(F.historical_session_count, NULLIF(DATE_DIFF(F.last_interaction_date, F.first_interaction_date, DAY), 0)) AS session_frequency_per_day,
  SAFE_DIVIDE(F.view_item_count, F.historical_session_count) AS view_items_per_session,

  IF(E.add_to_cart_label = 1, 1, 0) AS cart_label,
  IFNULL(PR.actual_purchase_revenue, 0) AS purchase_revenue,

  -- split 用全歷史真實最後活躍日 (兩表共用, 跨表一致)
  CASE
    WHEN ID.user_last_active_date BETWEEN '2020-11-01' AND '2020-12-31' THEN 'TRAIN'
    WHEN ID.user_last_active_date BETWEEN '2021-01-01' AND '2021-01-21' THEN 'VALIDATION'
    ELSE 'TEST_HOLDOUT'
  END AS data_split_label
FROM Base_Users AS F
INNER JOIN ${ref("user_identity")} AS ID ON F.user_pseudo_id = ID.user_pseudo_id
LEFT JOIN Add_to_cart_Labels AS E ON F.user_pseudo_id = E.user_pseudo_id
LEFT JOIN Purchase_Revenue AS PR ON F.user_pseudo_id = PR.user_pseudo_id
LEFT JOIN View_Item_Features AS VIF ON F.user_pseudo_id = VIF.user_pseudo_id
LEFT JOIN User_Maxrep AS UM ON F.user_pseudo_id = UM.user_pseudo_id
WHERE ID.traffic_source != 'Unknown'
  AND ID.device_category != 'Unknown'
