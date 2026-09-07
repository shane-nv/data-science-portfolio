"""
電信用戶流失分析與留存策略 — 邏輯斯迴歸（控制混淆變數）

說明：以 statsmodels 建立邏輯斯迴歸，控制合約類型、網路類型、月費與加值服務數量，
      分離各因子對流失的獨立效果並輸出勝算比（Odds Ratio）與 95% 信賴區間。
來源：本檔案自專案報告轉錄整理；完整排版見專案資料夾內的原始 PDF。
"""

import statsmodels.formula.api as smf
import pandas as pd
import numpy as np

# 清洗資料
data['Churn_Numeric'] = data['Churn'].map({'Yes': 1, 'No': 0})

# 計算加值服務數量
services = ['OnlineSecurity', 'OnlineBackup', 'DeviceProtection',
           'TechSupport', 'StreamingTV', 'StreamingMovies']
data['TotalServices'] = (data[services] == 'Yes').sum(axis=1)

# 只看 Fiber optic 與 DSL 用戶
sub_df = data[data['InternetService'].isin(['Fiber optic', 'DSL'])].copy()

# 建立包含月費的模型；加入 TotalServices 作為控制變數
model_final = smf.logit(
    'Churn_Numeric ~ C(Contract) + C(InternetService) + MonthlyCharges + TotalServices',
    data=sub_df
).fit()

# 轉換為勝算比 (Odds Ratio)
params = model_final.params
conf = model_final.conf_int()
conf['OR'] = params
df_or = np.exp(conf)
df_or.columns = ['5%', '95%', 'Odds Ratio']

print(model_final.summary())
print("\n--- 包含月費後的勝算比 (Odds Ratio) ---")
print(df_or)
