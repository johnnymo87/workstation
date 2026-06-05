-- Top-N users by Vertex AI call count this calendar month.
-- Backs Looker Studio panel: "Top users this month".
-- Excludes service accounts via the gserviceaccount.com suffix
-- (null-safe: rows with missing principalEmail are kept).
--
-- Call count is deduplicated by operation: Vertex streaming methods
-- (StreamGenerateContent, StreamRawPredict) emit TWO audit-log rows per call
-- (operation.first + operation.last, sharing one operation.id), so COUNT(*)
-- double-counts them. Non-streaming methods (EmbedContent, Predict, ...) emit
-- one row with a NULL operation.id, so we fall back to the always-unique
-- insertId. COUNT(DISTINCT IFNULL(operation.id, insertId)) handles both.
SELECT
  protopayload_auditlog.authenticationInfo.principalEmail AS user_email,
  COUNT(DISTINCT IFNULL(operation.id, insertId)) AS call_count
FROM
  `my-gcp-project.vertex_ai_audit_logs.cloudaudit_googleapis_com_data_access`
WHERE
  timestamp >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
  AND (
    protopayload_auditlog.authenticationInfo.principalEmail IS NULL
    OR NOT ENDS_WITH(protopayload_auditlog.authenticationInfo.principalEmail, '.gserviceaccount.com')
  )
GROUP BY
  user_email
ORDER BY
  call_count DESC
LIMIT 25;
