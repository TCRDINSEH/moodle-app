
# Moodle on Cloud Run with the existing CVE CSV exporter

This is a separate Moodle deployment. It leaves the Juice Shop Cloud Run
service and its Terraform state unchanged.

The Moodle web service runs on Cloud Run, Moodle's supported MySQL database
runs on Cloud SQL, and an isolated prefix in Cloud Storage holds Moodle's file
data and generated configuration. A Cloud Run Job and Cloud Scheduler run
Moodle's scheduled tasks. The existing Juice Shop CVE exporter scans every
image digest in its configured Artifact Registry repository; building Moodle
into that same repository includes its image in the existing daily CVE CSV
export. Vulnerability reports remain in the existing CVE bucket under its
configured prefix (normally `cve-findings`).

## Important demo limitations

- A Cloud Storage volume uses Cloud Storage FUSE, which does not provide full
  POSIX semantics or file locking. This configuration selects Moodle's
  database-backed lock factory, limits the web service to one instance, and is
  for a short classroom demonstration only. Do not use it for production or
  real student records.
- Moodle still needs SQL for courses, accounts, grades, and application state.
  Cloud Run can scale to zero, but Cloud SQL continues to incur charges while
  running. The shared-core SQL tier is a low-capacity demo setting, not a
  production recommendation.
- Terraform state contains the database and administrator passwords. Keep the
  local state and `terraform.tfvars` private; use a secured remote backend if
  sharing this deployment.
- The example reuses the existing CVE report bucket by default, but mounts only
  the `moodledata/` prefix for Moodle. The existing exporter continues writing
  CSV reports beneath `cve-findings/`. Cloud Run's GCS volume uses Cloud Storage
  FUSE, so a prefix is required to keep the two sets of objects separate.
- Moodle's container image is built from the selected stable Moodle Git branch.
  Review that branch and its PHP requirements before changing versions.
- The example is private by default. Enabling unauthenticated access exposes the
  site to anyone with its URL; do not collect real student data over this demo
  setup.

## Prerequisites

- Google Cloud project with billing enabled and permissions to enable APIs and
  create Cloud Run, Cloud SQL, Cloud Scheduler, Artifact Registry, IAM, Secret
  Manager, and Cloud Storage resources.
- `gcloud`, Docker, and Terraform 1.5 or later.
- Artifact Analysis vulnerability scanning enabled.
- The existing `vulnerability-registry` Artifact Registry repository and the
  Juice Shop CVE exporter stack deployed in `terraform-scripts/cloud-run`.

The CVE scanner lists all image digests in its configured Artifact Registry
repository. Do not deploy this Moodle image to a different repository if you
want the existing scanner to include it.

## Build and push the Moodle image

Run from the repository root in PowerShell. Use the same project, region, and
Artifact Registry repository configured in the Juice Shop Cloud Run stack:

```powershell
$Project = "YOUR_PROJECT_ID"
$Region = "asia-south1"
$Repository = "vulnerability-registry"
$Registry = "$Region-docker.pkg.dev/$Project/$Repository"

gcloud.cmd auth configure-docker "$Region-docker.pkg.dev"

docker build `
  --build-arg MOODLE_BRANCH=MOODLE_501_STABLE `
  -t "$Registry/moodle:latest" `
  .\terraform-scripts\cloud-run-moodle\app

docker push "$Registry/moodle:latest"
gcloud.cmd artifacts docker images list $Registry --include-tags
```

The startup script must retain Unix (LF) line endings so the Linux container can
execute its `/bin/sh` shebang. The app's `.gitattributes` enforces this for Git
checkouts.

If Docker Desktop is unavailable, enable Cloud Build and build from the
repository root instead:

```powershell
gcloud.cmd services enable cloudbuild.googleapis.com --project $Project
gcloud.cmd builds submit .\terraform-scripts\cloud-run-moodle\app `
  --tag "$Registry/moodle:latest" `
  --project $Project
```

If a Cloud Run revision exits with `Application exec likely failed`, rebuild
the image from the corrected LF-line-ending startup script using a new tag,
then set `moodle_image` to that new tag before applying. Do not rely on
re-pushing `latest` alone because Terraform may not detect a mutable-tag change:

```powershell
$FixTag = "$Registry/moodle:startup-fix7"
gcloud.cmd builds submit .\terraform-scripts\cloud-run-moodle\app `
  --tag $FixTag `
  --project $Project
```

Set `moodle_image` in `terraform.tfvars` to the value of `$FixTag`, then run
`terraform plan` and `terraform apply`. Use a new tag for each image rebuild.

Artifact Analysis scanning is asynchronous. Allow time for the Moodle image's
findings to appear before the existing scheduled export runs.

## Configure and deploy Moodle

```powershell
Set-Location .\terraform-scripts\cloud-run-moodle
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
```

Edit `terraform.tfvars`:

- Set the project ID and `moodle_image` to the image just pushed.
- Set `moodle_wwwroot` to the Cloud Run URL for the `moodle` service. For this
  project it is `https://moodle-720054743088.asia-south1.run.app`. You can check
  a service URL with
  `gcloud.cmd run services describe moodle --region $Region --project $Project --format="value(uri)"`.
- Set `moodledata_bucket_name` to the name of the existing bucket you want to
  reuse. Set `create_moodledata_bucket = false` to use it without making
  Terraform manage or delete the bucket.
- The default `moodledata_prefix = "moodledata"` keeps Moodle's files separate
  from the CVE exporter's `cve-findings/` objects. Keep a non-empty, dedicated
  prefix; do not mount the bucket root.
- Set the administrator email and two different strong passwords, each at
  least 16 characters.
- Leave `allow_unauthenticated = false` for a private service. Set it to `true`
  only if your instructor needs a public classroom demo.

Then run:

```powershell
gcloud.cmd auth application-default login
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

The initial Cloud Run startup installs Moodle into Cloud SQL and writes
Moodle's persistent configuration to the selected bucket prefix. Apache starts
only after installation completes, so the TCP startup probe allows up to ten
minutes for this first boot. If a revision is recreated after the database was
initialized but `config.php` was not persisted, the entrypoint now recreates
that file from the runtime settings instead of trying to initialize the
database again. Because Moodle's configuration is stored under the data mount,
startup also ensures its setup include points to the Moodle code directory
rather than resolving relative to the mounted configuration file. The
`moodle_wwwroot` input is supplied explicitly because Cloud Run does not publish
the service URI to startup code until service creation completes.

If creation still times out, inspect the failed revision's container logs before
increasing the probe window again. Look for Moodle installer errors, Cloud SQL
socket or authentication failures, and errors persisting `config.php` to the
mounted data volume:

```powershell
gcloud.cmd run services logs read moodle `
  --region $Region `
  --project $Project `
  --limit 100
```

### Upgrade the existing Cloud SQL instance before starting Moodle

The Moodle 5.1 branch requires MySQL 8.4 and PHP `max_input_vars` of at least
5000. The container image configures `max_input_vars`; the Terraform database
resource targets MySQL 8.4. The current instance was created as MySQL 8.0, so
upgrade it in place before applying the new configuration. Back up the
instance first and confirm that Cloud SQL lists MySQL 8.4 as an upgrade target:

```powershell
gcloud.cmd sql backups create `
  --instance=moodle-cloudrun-mysql `
  --project=$Project

gcloud.cmd sql instances describe moodle-cloudrun-mysql `
  --project=$Project `
  --format="yaml(databaseVersion,upgradableDatabaseVersions)"
```

When the backup is complete and `MYSQL_8_4` appears under
`upgradableDatabaseVersions`, perform the in-place upgrade:

```powershell
gcloud.cmd sql instances patch moodle-cloudrun-mysql `
  --database-version=MYSQL_8_4 `
  --project=$Project
```

Wait for Cloud SQL to return to `RUNNABLE` and report `MYSQL_8_4`. Then build
and push the configured Moodle image, run `terraform plan`, and check
that the plan does not propose replacing or deleting the database instance.
Cloud SQL major-version upgrades can involve downtime; do not proceed without
the backup and an approved maintenance window.

### If this Terraform root already created the Moodle bucket

If you previously applied the Moodle stack and its Terraform state already
tracks `google_storage_bucket.moodledata`, but now want to use that same bucket
in existing-bucket mode, first confirm that the bucket is the one you want to
retain. Check the exact state address first:

```powershell
terraform state list
```

The earlier uncounted configuration used this address:

```powershell
terraform state rm google_storage_bucket.moodledata
```

If your state instead lists `google_storage_bucket.moodledata[0]`, use that
exact address. Only remove the Moodle bucket entry if you intend to retain and
reuse that bucket as an external resource. The command changes Terraform state
only; it does not delete the bucket or its objects. Do not run `terraform state
rm` for a bucket that Terraform does not currently manage, and do not run
`terraform destroy` when protecting a bucket that contains other data.

## Open the service and review vulnerability reports

```powershell
terraform output
```

With the default private IAM policy, grant access to specific users:

```powershell
gcloud.cmd run services add-iam-policy-binding moodle `
  --region $Region `
  --project $Project `
  --member="user:YOUR_EMAIL" `
  --role="roles/run.invoker"
```

Sign in with the reported `moodle_admin_username` and the `admin_password`
entered in the local `terraform.tfvars`.

The existing Juice Shop CVE exporter continues writing timestamped CSV reports
to its existing bucket. To run it immediately:

```powershell
gcloud.cmd run jobs execute juice-shop-cve-export `
  --region $Region `
  --project $Project `
  --wait

gcloud.cmd storage ls "gs://YOUR_EXISTING_CVE_BUCKET/cve-findings/**"
```

The report includes CVEs for all images in the configured Artifact Registry
repository, including `moodle` after Artifact Analysis has finished scanning it.
Review Cloud Run Job logs if a scan execution fails.

## Cost and cleanup

Cloud Run scales the web service to zero when idle; Cloud SQL does not. Cloud
SQL is likely to be the main ongoing cost, with smaller charges possible for
storage, Artifact Registry, Cloud Scheduler, and network use. Check current
regional pricing and billing before deploying.

After the demo, remove only the Moodle stack:

```powershell
terraform destroy
```

Review the destroy plan carefully. In existing-bucket mode, it removes the
Moodle database and Cloud Run resources, the Moodle prefix marker, and the
Moodle IAM grant; it does not delete the reused bucket or the Juice Shop CVE
report objects. In create-bucket mode, it also removes the dedicated Moodle
bucket, which must be empty first.
