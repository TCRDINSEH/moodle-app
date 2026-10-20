project_id             = "project-fd365bc9-bf65-4f05-bfe"
region                 = "asia-south1"
artifact_repository_id = "vulnerability-registry"
moodle_image           = "asia-south1-docker.pkg.dev/project-fd365bc9-bf65-4f05-bfe/vulnerability-registry/moodle:1.0"
moodle_wwwroot         = "https://cve-dashboard-720054743088.asia-south1.run.app"

# Reuse the existing CVE report bucket. Moodle uses only the moodledata/ prefix;
# the existing CVE exporter continues using cve-findings/.
moodledata_bucket_name   = "vulnerability-scans-project-fd365bc9-bf65-4f05-bfe"
create_moodledata_bucket = false
moodledata_prefix        = "moodledata"

admin_email       = "drddha@gmail.com"
database_password = "project-fd365bc9-bf65-4f05-bfe"
admin_password    = "Projectfd365bc9bf654f05bfe@"

# Set true only if you want unauthenticated access to the classroom demo.
allow_unauthenticated = false
