output "moodle_url" {
  description = "HTTPS URL of the Moodle Cloud Run service."
  value       = google_cloud_run_v2_service.moodle.uri
}

output "moodle_admin_username" {
  description = "Initial Moodle administrator username."
  value       = var.admin_username
}

output "moodledata_bucket" {
  description = "Cloud Storage bucket containing Moodle's isolated persistent file prefix."
  value       = local.moodledata_bucket
}

output "moodledata_prefix" {
  description = "Isolated object prefix mounted by Moodle for persistent file data."
  value       = var.moodledata_prefix
}

output "sql_instance_name" {
  description = "Cloud SQL MySQL instance name."
  value       = google_sql_database_instance.moodle.name
}

output "cron_job_name" {
  description = "Cloud Run Job that executes Moodle scheduled tasks."
  value       = google_cloud_run_v2_job.cron.name
}
