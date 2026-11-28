# mlowcher61.ai_governance changelog

## 0.1.0

- New module `cloudwatch_metric_data_info`: list CloudWatch metrics and read their data points (read-only), for usage collection.
- New module `agentcore_runtime_invoke`: invoke an AgentCore runtime (demo traffic only).
- New filters `usage_queries`, `usage_api_queries`, `usage_rows`: daily AI usage rows and estimated cost.
- New module `iam_policy_simulation_info`: evaluate IAM actions for a principal with the IAM policy simulator, with expected outcomes for negative tests and remediation verification.
