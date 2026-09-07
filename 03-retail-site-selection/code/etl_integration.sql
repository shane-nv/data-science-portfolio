/*
 * 展店選址智慧系統 — 多源異質資料整合（ETL 補值腳本）
 * 平台：MySQL
 * 說明：依各政府開放資料源的地理粒度動態調整 JOIN Key（縣市＋行政區＋村里），
 *      逐一補值地理、人流、所得、消費熱度、競爭與租金六大維度特徵；
 *      租金以子查詢 GROUP BY + MAX 先聚合，避免一對多 JOIN 造成樣本膨脹。
 * 來源：本檔案自專案報告轉錄整理；完整排版見專案資料夾內的原始 PDF。
 */

-- 暫時關閉安全模式
SET SQL_SAFE_UPDATES = 0;

-- 地理行政區補值（v0.6_fixed），用經緯度比對，補上縣市、行政區、里別
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `資料訓練大表_v0.6_fixed_no_id` AS A
    ON main.店_緯度 = A.店_緯度 AND main.店_經度 = A.店_經度
SET
    main.縣市 = A.縣市,
    main.行政區 = A.行政區,
    main.里別 = A.里別
WHERE
    main.縣市 = '找不到'
    OR main.行政區 = '找不到'
    OR main.里別 = '找不到';

-- 電信信令人口統計，補上平日／假日的日間活動人數與夜間停留人數
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `電信信令人口統計資料` AS A
    ON main.縣市 = A.縣市 AND main.行政區 = A.鄉鎮市區
SET
    main.行政區平日夜間停留人數 = A.平日夜間停留人數,
    main.行政區平日日間活動人數 = A.平日日間活動人數,
    main.行政區假日夜間停留人數 = A.假日夜間停留人數,
    main.行政區假日日間活動人數 = A.假日日間活動人數
WHERE
    main.行政區平日夜間停留人數 IS NULL
    OR main.行政區平日日間活動人數 IS NULL
    OR main.行政區假日夜間停留人數 IS NULL
    OR main.行政區假日日間活動人數 IS NULL;

-- 雙北所得稅資料，補上里人均收入中位數
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `雙北所得稅` AS A
    ON main.行政區 = A.鄉鎮市區 AND main.里別 = A.村里
SET
    main.里人均收入中位數 = A.中位數
WHERE
    main.里人均收入中位數 IS NULL;

-- 雙北設籍人口，補上里人口數
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `雙北設籍人口` AS A
    ON main.行政區 = A.鄉鎮市區 AND main.里別 = A.村里
SET
    main.里人口數 = A.人口數
WHERE
    main.里人口數 IS NULL;

-- 觀光景點消費熱度，補上發票張數與銷售額指標
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `雙北觀光景點消費熱度分析` AS A
    ON main.行政區 = A.鄉鎮市區 AND main.里別 = A.村里
SET
    main.發票張數指標 = A.張數指標,
    main.發票銷售額指標 = A.銷售額指標
WHERE
    main.發票張數指標 IS NULL
    OR main.發票銷售額指標 IS NULL;

-- 超商超市競爭距離，補上店家經緯度、500 公尺內競爭者數量、熱鬧據點等地理商業特徵
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN `雙北超商超市_競爭距離` AS A
    ON main.分公司名稱 = A.分公司名稱 AND main.分公司核准設立日期 = A.分公司核准設立日期
SET
    main.`店_緯度` = A.`店_緯度`,
    main.`店_經度` = A.`店_經度`,
    main.`500公尺內的熱鬧據點數` = A.`500公尺內的熱鬧據點數`,
    main.最近的熱鬧據點類型 = A.最近的熱鬧據點類型,
    main.最近的熱鬧據點距離 = A.最近的熱鬧據點距離,
    main.`500公尺內部競爭(同公司店數)` = A.`500公尺內部競爭(同公司店數)`,
    main.`500公尺外部競爭(不同公司店數)` = A.`500公尺外部競爭(不同公司店數)`,
    main.`500公尺內部競爭_時間(同公司店數)` = A.`500公尺內部競爭_時間(同公司店數)`,
    main.`500公尺外部競爭_時間(不同公司店數)` = A.`500公尺外部競爭_時間(不同公司店數)`
WHERE
    main.`店_緯度` IS NULL
    OR main.`店_經度` IS NULL
    OR main.`500公尺內的熱鬧據點數` IS NULL
    OR main.最近的熱鬧據點類型 IS NULL
    OR main.最近的熱鬧據點距離 IS NULL
    OR main.`500公尺內部競爭(同公司店數)` IS NULL
    OR main.`500公尺外部競爭(不同公司店數)` IS NULL
    OR main.`500公尺內部競爭_時間(同公司店數)` IS NULL
    OR main.`500公尺外部競爭_時間(不同公司店數)` IS NULL;

-- 租金資料 — 用子查詢取每個里的最高租金補值（先聚合避免樣本膨脹）
UPDATE `資料訓練大表_v0.5` AS main
INNER JOIN (
    SELECT 縣市, 鄉鎮市區, 村里, MAX(租金) AS 租金
    FROM `雙北超商租金`
    GROUP BY 縣市, 鄉鎮市區, 村里
) AS rent
    ON main.行政區 = rent.鄉鎮市區 AND main.里別 = rent.村里
SET main.租金 = rent.租金
WHERE main.租金 IS NULL OR main.租金 = 0;  -- 只針對沒值的地方更新

-- 把安全模式開回來，保護資料安全
SET SQL_SAFE_UPDATES = 1;
