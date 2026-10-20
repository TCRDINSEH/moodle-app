variable "project_id" {
  description = "Google Cloud project ID with billing enabled."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Cloud SQL, Artifact Registry, and buckets."
  type        = string
  default     = "asia-south1"
}

variable "artifact_repository_id" {
  description = "Artifact Registry Docker repository also scanned by the existing Juice Shop CVE exporter."
  type        = string
  default     = "vulnerability-registry"
}

variable "moodle_image" {
  description = "Full Artifact Registry URI and tag/digest for the Moodle container image."
  type        = string
}

variable "service_name" {
  description = "Cloud Run service name for Moodle."
  type        = string
  default     = "cve-dashboard-1"
}

variable "moodle_wwwroot" {
  description = "Stable HTTPS URL Cloud Run assigns to this service. Used for Moodle's canonical site URL during first boot."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.moodle_wwwroot))
    error_message = "moodle_wwwroot must be an HTTPS origin without a trailing path."
  }
}

variable "allow_unauthenticated" {
  description = "Allow public internet users to invoke this demo Moodle site."
  type        = bool
  default     = false
}

variable "sql_instance_name" {
  description = "Cloud SQL MySQL instance name."
  type        = string
  default     = "moodle-cloudrun-mysql"
}

variable "sql_tier" {
  description = "Cloud SQL Enterprise edition machine tier. The shared-core default is for demos only."
  type        = string
  default     = "db-f1-micro"
}

variable "sql_disk_size_gb" {
  description = "Initial Cloud SQL disk size in GB; automatic storage increase is enabled."
  type        = number
  default     = 10
}

variable "enable_automated_backups" {
  description = "Enable Cloud SQL automated backups. Disabled by default for a disposable demo."
  type        = bool
  default     = false
}

variable "sql_database_name" {
  description = "Moodle database name."
  type        = string
  default     = "moodle"
}

variable "sql_username" {
  description = "Moodle application database username."
  type        = string
  default     = "moodle_app"
}

variable "database_password" {
  description = "Strong Cloud SQL password, also stored in Secret Manager."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.database_password) >= 16
    error_message = "The database password must contain at least 16 characters."
  }
}

variable "moodledata_bucket_name" {
  description = "Name of the existing bucket to reuse, or new bucket name when create_moodledata_bucket is true."
  type        = string
}

variable "create_moodledata_bucket" {
  description = "Create a new Moodle data bucket instead of using the existing bucket named by moodledata_bucket_name."
  type        = bool
  default     = false
}

variable "moodledata_prefix" {
  description = "Isolated object prefix within the Moodle data bucket."
  type        = string
  default     = "moodledata"

  validation {
    condition     = trim(var.moodledata_prefix, "/") != ""
    error_message = "The Moodle data prefix must not be empty."
  }
}

variable "admin_username" {
  description = "Initial Moodle administrator username."
  type        = string
  default     = "siteadmin"
}

variable "admin_password" {
  description = "Strong initial Moodle administrator password, also stored in Secret Manager."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.admin_password) >= 16 &&
      can(regex("[a-z]", var.admin_password)) &&
      can(regex("[A-Z]", var.admin_password)) &&
      can(regex("[0-9]", var.admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.admin_password))
    )
    error_message = "The administrator password must be at least 16 characters and include lowercase, uppercase, numeric, and non-alphanumeric characters."
  }
}

variable "admin_email" {
  description = "Email address for the initial Moodle site administrator."
  type        = string

  validation {
    condition     = can(regex("^[^ @]+@[^ @]+\\.[^ @]+$", var.admin_email))
    error_message = "Provide a valid administrator email address."
  }
}

variable "site_fullname" {
  description = "Full name shown for the Moodle site."
  type        = string
  default     = "Moodle Learning Site"
}

variable "site_shortname" {
  description = "Short Moodle site name."
  type        = string
  default     = "Moodle"
}

variable "runtime_service_account_id" {
  description = "Service account ID used by the Moodle Cloud Run service and cron job."
  type        = string
  default     = "moodle-cloudrun-runtime"
}

variable "scheduler_service_account_id" {
  description = "Service account ID used by Cloud Scheduler to invoke the Moodle cron job."
  type        = string
  default     = "moodle-cron-scheduler"
}

variable "cron_job_name" {
  description = "Cloud Run Job name for Moodle's scheduled CLI tasks."
  type        = string
  default     = "cve-scanner"
}
