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
| Credential types | `AI Governance - AWS Discovery Role`, `AI Governance - AWS Remediation Role`, `AI Governance - AWS Demo Reset Role` |
| Credentials | One per governance role (role ARN + randomly generated external ID, created once and never overwritten) |
| Project | `AI Governance Control Tower` (this Git repository) |
| Inventory | `AI Governance - Localhost` |
| Execution environment | `AI Governance EE` (registered once `aigov_custom_ee_image` is set, after `scripts/build_ee.sh`) |
| Job templates | `AI Governance - Check Environment`, `- Deploy AWS Governance Roles`, `- Deploy Demo Agents`, `- Verify AWS Baseline` |

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

## Secrets

- The AAP token and the hub token come only from environment variables.
- The governance role **external IDs** are generated randomly the first time each credential is created.
  They live only in the AAP credentials and in the CloudFormation stack parameters (`NoEcho`).
- No Ansible Vault files are used, and no secrets are stored in Git.
