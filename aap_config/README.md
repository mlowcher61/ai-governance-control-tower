# Configure Ansible Automation Platform (config as code)

Everything the AI Governance Control Tower needs in Ansible Automation Platform (AAP) is defined in this
folder and applied with the Red Hat validated collection `infra.aap_configuration`. Re-running the
playbook is safe: it converges AAP to these definitions.

## What gets created

| Object | Name |
|---|---|
| Organization | `AI Governance` (uses your private automation hub for collections) |
| Galaxy credentials | `AI Governance - Private Hub Certified`, `AI Governance - Private Hub Validated` |
| Source Control credential | `AI Governance - GitHub` (only when `AIGOV_SCM_TOKEN`/`GITHUB_TOKEN` is set, for a private repository) |
| Credential types | `AI Governance - AWS Discovery Role`, `AI Governance - AWS Remediation Role`, `AI Governance - AWS Demo Reset Role`, `AI Governance - Automation Orchestrator`, `AI Governance - Inventory API`, `AI Governance - ServiceNow` |
| Credentials | One per governance role (role ARN + randomly generated external ID, created once and never overwritten). `AI Governance - Automation Orchestrator` (when `aigov_ao_url` is set): the AO URL plus the `aigov-trigger` client ID and secret, which `ao_workflows/configure_ao.yml` writes once and this playbook never overwrites. `AI Governance - Inventory API (<role>)` for each API role (discovery, registry, evaluator, remediator, reader, auditor) when `aigov_openshift_credential` is set. They are created with an empty token; **Issue API Tokens** fills them in, and this playbook never overwrites the token. `AI Governance - ServiceNow`: the instance URL (`aigov_servicenow_instance`), username and password for WF-02 incidents. It is created once (empty if not set); enter the account in AAP, or export `AIGOV_SERVICENOW_USERNAME`/`AIGOV_SERVICENOW_PASSWORD` when running this playbook. An empty instance means notifications are skipped and only audited |
| Project | `AI Governance Control Tower` (this Git repository) |
| Inventory | `AI Governance - Localhost` |
| Execution environment | `AI Governance EE` (registered once `aigov_custom_ee_image` is set, after `scripts/build_ee.sh`). It is pulled with `aigov_ee_registry_credential`, a hub username/password credential, because an AAP token gets only anonymous registry access |
| Job templates | `AI Governance - Check Environment`; AWS: `- Deploy AWS Governance Roles`, `- Deploy Demo Agents`, `- Verify AWS Baseline` (when `aigov_aws_account_id` is set); platform: `- Deploy Platform Services`, `- Apply Database Migrations` (when `aigov_openshift_credential` is set), `- Issue API Tokens` (also needs `aigov_aap_credential`); automation orchestrator: `- Configure Automation Orchestrator`, `- Apply AO Workflows` (when `aigov_ao_url` is set), `- Configure AO Network Allowlist` (also needs `aigov_openshift_credential`) |

Why three role credential types? AAP allows only one credential of each type on a job template, so a
template that only has the *discovery* type can never assume the *remediation* role.

## Steps for a new environment

1. Install the configuration collections from your private automation hub:

   ```bash
   ansible-galaxy collection install -r aap_config/requirements.yml
   ```

2. Copy and edit the customer variables (this file is git-ignored):

   ```bash
   cp aap_config/vars/customer.example.yml aap_config/vars/customer.yml
   ```

   Set `aigov_aws_bootstrap_credential` to an existing AAP credential of type **Amazon Web Services**
   (name or numeric ID). Leave `aigov_aws_account_id` empty for the first run.

3. Export the platform connection (never commit tokens):

   ```bash
   export AAP_SERVER=aap.example.com        # platform gateway host, no https://
   export AAP_API_TOKEN=<your AAP token>
   # optional: a dedicated private hub token for collection installs
   export AIGOV_HUB_TOKEN=<hub token>
   # private project repository only: a GitHub token with read access to the repo
   export AIGOV_SCM_TOKEN=<github token>
   ```

4. First run, which creates the organization, project and the `Check Environment` job template:

   ```bash
   ansible-playbook aap_config/configure_aap.yml
   ```

5. Launch **AI Governance - Check Environment** in AAP. Copy the AWS account ID it reports into
   `aigov_aws_account_id`, then run the playbook again. This adds the governance role credentials and the
   AWS job templates.

6. In AAP, run in order:
   1. **AI Governance - Deploy AWS Governance Roles**
   2. **AI Governance - Deploy Demo Agents**
   3. **AI Governance - Verify AWS Baseline**. It must report every least-privilege check as passed and all four demo runtimes as `READY`.

7. **Governance platform services (OpenShift).** In `customer.yml`, set `aigov_openshift_credential` to an existing
   AAP credential of type **OpenShift or Kubernetes API Bearer Token**. Its token must be able to create a namespace
   and Deployments, StatefulSets, Services, Routes, ConfigMaps, Secrets, NetworkPolicies and Jobs in it. Also set
   `aigov_platform_namespace` (default `ai-governance`) and `aigov_platform_trusted_namespaces`: the namespaces of AAP job
   pods and the AO worker, which are the only callers allowed to reach OPA and the Inventory API. Re-run this playbook,
   then launch in AAP:
   1. **AI Governance - Deploy Platform Services**. This deploys PostgreSQL, PostgREST, OPA, Grafana and the NetworkPolicies, then
      runs acceptance checks. It prints the Grafana URL; the admin password is in the Secret `<namespace>/grafana-admin`.
   2. **AI Governance - Apply Database Migrations**. This applies `database/migrations/`. A re-run with no new migrations reports `changed=0`.
   3. **AI Governance - Issue API Tokens**. First set `aigov_aap_credential` in `customer.yml` to an existing AAP credential of type
      **Red Hat Ansible Automation Platform** that can update credentials in the organization, and re-run this playbook. The job signs one
      Inventory API token per PostgreSQL role with the PostgREST secret, checks that each token runs as its own role, runs the
      read-only API tests, and stores each token in its *AI Governance - Inventory API (&lt;role&gt;)* credential. Tokens last
      `aigov_api_token_ttl_days` (default 90). Re-run the job to rotate them.

8. **automation orchestrator.** Set `aigov_ao_url` (the AO route URL) in `customer.yml` and re-run this playbook. Then, from a
   workstation with `AO_URL`, `AO_CLIENT_ID`, `AO_CLIENT_SECRET`, `AAP_SERVER` and `AAP_API_TOKEN` exported, run
   `ansible-playbook ao_workflows/configure_ao.yml`. It creates the `aigov-trigger` service account, gives it its project role,
   and stores its client credential in AAP. After that, the AO job templates work from AAP. See
   [ao_workflows/README.md](../ao_workflows/README.md).

## Secrets

- The AAP token and the hub token come only from environment variables.
- The platform secrets (database passwords, the PostgREST JWT secret, the Grafana admin password) are generated on the first deploy.
  They live only in Kubernetes Secrets and are never overwritten or printed.
- The `aigov-trigger` client secret is issued by AO once and written straight into the AAP credential (`no_log`).
- The Inventory API tokens are signed inside the **Issue API Tokens** job and written straight into the AAP credentials (`no_log`). The signing secret stays in the Kubernetes Secret `<namespace>/governance-api`.
- The governance role **external IDs** are generated randomly the first time each credential is created.
  They live only in the AAP credentials and in the CloudFormation stack parameters (`NoEcho`).
- No Ansible Vault files are used, and no secrets are stored in Git.
