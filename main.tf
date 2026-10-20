terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  required_apis = toset([
    "artifactregistry.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com"
  ])

  cloudsql_volume_name = "cloudsql"
  data_volume_name     = "moodle-data"
  cloudsql_socket      = "/cloudsql/${google_sql_database_instance.moodle.connection_name}"
  moodledata_bucket = var.create_moodledata_bucket ? (
    google_storage_bucket.moodledata[0].name
  ) : data.google_storage_bucket.existing_moodledata[0].name
}

resource "google_project_service" "apis" {
  for_each = local.required_apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repository_id
}

resource "google_secret_manager_secret" "database_password" {
  secret_id = "${var.service_name}-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "database_password" {
  secret      = google_secret_manager_secret.database_password.id
  secret_data = var.database_password
}

resource "google_secret_manager_secret" "admin_password" {
  secret_id = "${var.service_name}-admin-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = var.admin_password
}

resource "google_storage_bucket" "moodledata" {
  count                       = var.create_moodledata_bucket ? 1 : 0
  name                        = var.moodledata_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  depends_on = [google_project_service.apis["storage.googleapis.com"]]
}

data "google_storage_bucket" "existing_moodledata" {
  count = var.create_moodledata_bucket ? 0 : 1
  name  = var.moodledata_bucket_name

  depends_on = [google_project_service.apis["storage.googleapis.com"]]
}

resource "google_storage_bucket_object" "moodledata_prefix" {
  bucket  = local.moodledata_bucket
  name    = "${trim(var.moodledata_prefix, "/")}/.moodle-prefix"
  content = "Reserved for Moodle application files."

  depends_on = [google_project_service.apis["storage.googleapis.com"]]
}

resource "google_sql_database_instance" "moodle" {
  name                = var.sql_instance_name
  region              = var.region
  database_version    = "MYSQL_8_4"
  deletion_protection = false

  settings {
    edition           = "ENTERPRISE"
    tier              = var.sql_tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.sql_disk_size_gb
    disk_autoresize   = true

    backup_configuration {
      enabled = var.enable_automated_backups
    }

    ip_configuration {
      ipv4_enabled = true
    }
  }

  depends_on = [google_project_service.apis["sqladmin.googleapis.com"]]
}

resource "google_sql_database" "moodle" {
  name      = var.sql_database_name
  instance  = google_sql_database_instance.moodle.name
  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"
}

resource "google_sql_user" "moodle" {
  name     = var.sql_username
  instance = google_sql_database_instance.moodle.name
  password = var.database_password
}

resource "google_service_account" "moodle" {
  account_id   = var.runtime_service_account_id
  display_name = "Moodle Cloud Run runtime"

  depends_on = [google_project_service.apis["iam.googleapis.com"]]
}

resource "google_project_iam_member" "moodle_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.moodle.email}"
}

resource "google_storage_bucket_iam_member" "moodledata_user" {
  bucket = local.moodledata_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.moodle.email}"
}

resource "google_secret_manager_secret_iam_member" "moodle_database_password" {
  secret_id = google_secret_manager_secret.database_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.moodle.email}"
}

resource "google_secret_manager_secret_iam_member" "moodle_admin_password" {
  secret_id = google_secret_manager_secret.admin_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.moodle.email}"
}

resource "google_cloud_run_v2_service" "moodle" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.moodle.email
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    volumes {
      name = local.cloudsql_volume_name

      cloud_sql_instance {
        instances = [google_sql_database_instance.moodle.connection_name]
      }
    }

    volumes {
      name = local.data_volume_name

      gcs {
        bucket    = local.moodledata_bucket
        read_only = false
        mount_options = [
          "only-dir=${trim(var.moodledata_prefix, "/")}",
          "uid=33",
          "gid=33",
          "dir-mode=0770",
          "file-mode=0660"
        ]
      }
    }

    containers {
      image = var.moodle_image

      ports {
        container_port = 8080
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      env {
        name  = "GCP_REGION"
        value = var.region
      }

      env {
        name  = "MOODLE_SERVICE_NAME"
        value = var.service_name
      }

      env {
        name  = "MOODLE_WWWROOT"
        value = var.moodle_wwwroot
      }

      env {
        name  = "MOODLE_DB_NAME"
        value = google_sql_database.moodle.name
      }

      env {
        name  = "MOODLE_DB_USER"
        value = google_sql_user.moodle.name
      }

      env {
        name  = "MOODLE_DB_SOCKET"
        value = local.cloudsql_socket
      }

      env {
        name  = "MOODLE_ADMIN_USER"
        value = var.admin_username
      }

      env {
        name  = "MOODLE_ADMIN_EMAIL"
        value = var.admin_email
      }

      env {
        name  = "MOODLE_SITE_FULLNAME"
        value = var.site_fullname
      }

      env {
        name  = "MOODLE_SITE_SHORTNAME"
        value = var.site_shortname
      }

      env {
        name = "MOODLE_DB_PASSWORD"

        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_password.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "MOODLE_ADMIN_PASSWORD"

        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.admin_password.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = local.cloudsql_volume_name
        mount_path = "/cloudsql"
      }

      volume_mounts {
        name       = local.data_volume_name
        mount_path = "/var/moodledata"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      startup_probe {
        period_seconds    = 10
        timeout_seconds   = 10
        failure_threshold = 60

        tcp_socket {
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis["run.googleapis.com"],
    google_project_iam_member.moodle_cloudsql_client,
    google_storage_bucket_iam_member.moodledata_user,
    google_secret_manager_secret_iam_member.moodle_database_password,
    google_secret_manager_secret_iam_member.moodle_admin_password,
    google_sql_database.moodle,
    google_sql_user.moodle,
    data.google_artifact_registry_repository.images
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = google_cloud_run_v2_service.moodle.location
  name     = google_cloud_run_v2_service.moodle.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_service_account" "scheduler" {
  account_id   = var.scheduler_service_account_id
  display_name = "Moodle Cloud Run cron scheduler"

  depends_on = [google_project_service.apis["iam.googleapis.com"]]
}

resource "google_cloud_run_v2_job" "cron" {
  name                = var.cron_job_name
  location            = var.region
  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.moodle.email
      timeout         = "900s"
      max_retries     = 1

      volumes {
        name = local.cloudsql_volume_name

        cloud_sql_instance {
          instances = [google_sql_database_instance.moodle.connection_name]
        }
      }

      volumes {
        name = local.data_volume_name

        gcs {
          bucket    = local.moodledata_bucket
          read_only = false
          mount_options = [
            "only-dir=${trim(var.moodledata_prefix, "/")}",
            "uid=33",
            "gid=33",
            "dir-mode=0770",
            "file-mode=0660"
          ]
        }
      }

      containers {
        image   = var.moodle_image
        command = ["/usr/local/bin/moodle-entrypoint"]
        args    = ["php", "/var/www/moodle/admin/cli/cron.php"]

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }

        env {
          name  = "GCP_REGION"
          value = var.region
        }

        env {
          name  = "MOODLE_SERVICE_NAME"
          value = var.service_name
        }

        env {
          name  = "MOODLE_WWWROOT"
          value = var.moodle_wwwroot
        }

        env {
          name  = "MOODLE_DB_NAME"
          value = google_sql_database.moodle.name
        }

        env {
          name  = "MOODLE_DB_USER"
          value = google_sql_user.moodle.name
        }

        env {
          name  = "MOODLE_DB_SOCKET"
          value = local.cloudsql_socket
        }

        env {
          name = "MOODLE_DB_PASSWORD"

          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.database_password.secret_id
              version = "latest"
            }
          }
        }

        volume_mounts {
          name       = local.cloudsql_volume_name
          mount_path = "/cloudsql"
        }

        volume_mounts {
          name       = local.data_volume_name
          mount_path = "/var/moodledata"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_service.moodle,
    google_cloud_run_v2_service_iam_member.public_invoker
  ]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_job.cron.location
  name     = google_cloud_run_v2_job.cron.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "moodle_cron" {
  name             = "${var.cron_job_name}-every-minute"
  region           = var.region
  schedule         = "* * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "320s"

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${var.cron_job_name}:run"
    body        = base64encode("{}")

    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.apis["cloudscheduler.googleapis.com"],
    google_cloud_run_v2_job_iam_member.scheduler_invoker
  ]
}
