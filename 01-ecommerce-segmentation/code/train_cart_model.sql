/*
 * 電商分眾決策模擬系統 — XGBoost 加車模型訓練
 * 平台：BigQuery ML / Dataform（SQLX）
 * 說明：以自訂時序切分（CUSTOM split）訓練 BOOSTED_TREE_CLASSIFIER，並開啟全域可解釋性與 Vertex AI 註冊。
 * 來源：本檔案自專案報告轉錄整理；完整排版見專案資料夾內的原始 PDF。
 */

config {
  type: "operations",
  schema: "ga4_ml_us",
  hasOutput: true,
  dependencies: ["ga4_features_cart"],
  name: "predict_add_to_cart_model",
  description: "進階模型：XGBoost"
}

CREATE OR REPLACE MODEL ${self()}
TRANSFORM(
  cart_label,
  ML.STANDARD_SCALER(log_total_engaged_time_seconds) OVER() AS log_total_engaged_time_seconds,
  ML.STANDARD_SCALER(log_unique_categories_viewed) OVER() AS log_unique_categories_viewed,
  ML.STANDARD_SCALER(log_avg_price_viewed) OVER() AS log_avg_price_viewed,
  ML.STANDARD_SCALER(log_max_item_rep_views) OVER() AS log_max_item_rep_views,
  ML.STANDARD_SCALER(item_focus_ratio) OVER() AS item_focus_ratio,
  ML.STANDARD_SCALER(days_in_dataset) OVER() AS days_in_dataset,
  ML.STANDARD_SCALER(session_frequency_per_day) OVER() AS session_frequency_per_day,
  ML.STANDARD_SCALER(view_items_per_session) OVER() AS view_items_per_session,
  device_category,
  traffic_source,
  is_returning_user,
  hpo_split_col
)
OPTIONS(
  model_type='BOOSTED_TREE_CLASSIFIER',
  input_label_cols=['cart_label'],
  DATA_SPLIT_METHOD = 'CUSTOM',
  DATA_SPLIT_COL = 'hpo_split_col',
  AUTO_CLASS_WEIGHTS = TRUE,
  ENABLE_GLOBAL_EXPLAIN = TRUE,
  num_trials = 20,
  max_parallel_trials = 2,
  hparam_tuning_objectives = ['ROC_AUC'],
  LEARN_RATE = HPARAM_RANGE(0.01, 0.3),
  MAX_TREE_DEPTH = HPARAM_CANDIDATES([4, 6, 8, 10]),
  MIN_TREE_CHILD_WEIGHT = HPARAM_RANGE(1, 10),
  model_registry = 'vertex_ai',
  vertex_ai_model_id = 'ga4_cart_model',
  vertex_ai_model_version_aliases = ['xgb']
) AS
SELECT
  log_total_engaged_time_seconds,
  log_unique_categories_viewed,
  log_avg_price_viewed,
  log_max_item_rep_views,
  item_focus_ratio,
  days_in_dataset,
  session_frequency_per_day,
  view_items_per_session,
  is_returning_user,
  device_category,
  traffic_source,
  user_pseudo_id,
  cart_label,
  IF(data_split_label = 'VALIDATION', 'EVAL', 'TRAIN') AS hpo_split_col
FROM ${ref("ga4_features_cart")}
WHERE view_item_count > 0
  AND data_split_label IN ('TRAIN', 'VALIDATION')
