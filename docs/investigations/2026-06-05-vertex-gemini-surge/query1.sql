-- Per-user daily Vertex AI call counts over the last 30 days.
-- Backs Looker Studio panel: "Per-user time series, last 30 days".
--
-- Call count is deduplicated by operation: Vertex streaming methods
-- (StreamGenerateContent, StreamRawPredict) emit TWO audit-log rows per call
-- (operation.first + operation.last, sharing one operation.id), so COUNT(*)
-- double-counts them. Non-streaming methods (EmbedContent, Predict, ...) emit
-- one row with a NULL operation.id, so we fall back to the always-unique
-- insertId. COUNT(DISTINCT IFNULL(operation.id, insertId)) handles both.
SELECT
  DATE(timestamp) AS day,
  protopayload_auditlog.authenticationInfo.principalEmail AS user_email,
  IFNULL(
    REGEXP_EXTRACT(
      protopayload_auditlog.resourceName,
      r'/publishers/[^/]+/models/([^/]+)'
    ),
    'unknown_model'
  ) AS model,
  COUNT(DISTINCT IFNULL(operation.id, insertId)) AS call_count
FROM
  `my-gcp-project.vertex_ai_audit_logs.cloudaudit_googleapis_com_data_access`
WHERE
  timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND (
    protopayload_auditlog.authenticationInfo.principalEmail IS NULL
    OR NOT ENDS_WITH(protopayload_auditlog.authenticationInfo.principalEmail, '.gserviceaccount.com')
  )
GROUP BY
  day, user_email, model
ORDER BY
  day DESC, call_count DESC;
