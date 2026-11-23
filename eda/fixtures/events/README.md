# Captured change events (task T3.01)

Real EventBridge events from the demo account, captured on 2026-11-23 by **AI Governance - Capture Change Events**
(`aigov_capture_bodies: true`) after **Set Demo Scenario** and **Reset Demo Agents**. The account ID, source IP
address and access key IDs are replaced with documentation values.

| File | `source` | `detail.eventSource` | Notes |
|---|---|---|---|
| `bedrock-agentcore-tagresource.json` | `aws.bedrock-agentcore` | `bedrock-agentcore.amazonaws.com` | Runtime tagged (`requestParameters.resourceArn` is the runtime ARN) |
| `bedrock-agentcore-untagresource.json` | `aws.bedrock-agentcore` | `bedrock-agentcore.amazonaws.com` | Runtime tag removed |
| `iam-attachrolepolicy.json` | `aws.iam` | `iam.amazonaws.com` | Delivered to us-east-1 and forwarded to the agent Region (`region: us-east-1`) |
| `iam-detachrolepolicy.json` | `aws.iam` | `iam.amazonaws.com` | Same |

These confirm the EventBridge patterns in `aws/cloudformation/aigov-events*.yaml` (docs/plan/05 section 2.5). Bedrock
Agents Classic events (`aws.bedrock`, `bedrock.amazonaws.com`) are not captured: the demo account has no Classic agents.
The EDA rulebook tests (T3.02) replay these files.
