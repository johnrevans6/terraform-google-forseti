/**
 * Copyright 2018 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

resource "random_string" "rand" {
  length  = 7
  special = false
  upper   = false
}

/******************************************
  Locals configuration
 *****************************************/
locals {
  project_id = "${var.project_id}"

  org_id               = "${var.org_id}"
  should_download      = "${var.download_forseti == "true" ? true : false}"
  skip_sendgrid_config = "${var.sendgrid_api_key == ""}"

  services_list = [
    "admin.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "bigquery-json.googleapis.com",
    "cloudbilling.googleapis.com",
    "sql-component.googleapis.com",
    "sqladmin.googleapis.com",
    "compute.googleapis.com",
    "deploymentmanager.googleapis.com",
    "iam.googleapis.com",
  ]

  server_org_roles = [
    "roles/browser",
    "roles/compute.networkViewer",
    "roles/iam.securityReviewer",
    "roles/appengine.appViewer",
    "roles/bigquery.dataViewer",
    "roles/servicemanagement.quotaViewer",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/cloudsql.viewer",
    "roles/compute.securityAdmin",
  ]

  server_project_roles = [
    "roles/storage.objectViewer",
    "roles/storage.objectCreator",
    "roles/cloudsql.client",
    "roles/logging.logWriter",
  ]

  client_roles = [
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
  ]

  launch_command_main        = "python install/gcp_installer.py --no-cloudshell --service-account-key-file ${var.credentials_file_path} --gsuite-superadmin-email ${var.gsuite_admin_email}"
  launch_command_gcs         = "${var.gcs_location != "" ? format("--gcs-location %s", var.gcs_location) : "--gcs-location \"\""}"
  launch_command_cloudsql    = "${var.cloud_sql_region != "" ? format("--cloudsql-region %s", var.cloud_sql_region) : "--cloudsql-region \"\"" }"
  launch_command_sendgrid    = "${var.sendgrid_api_key != "" ? format("--sendgrid-api-key %s", var.sendgrid_api_key) : "--skip-sendgrid-config" }"
  launch_command_email_notif = "${var.notification_recipient_email != "" && !local.skip_sendgrid_config ? format("--notification-recipient-email %s", var.notification_recipient_email) : ""}"
  launch_command_list        = "${compact(list(local.launch_command_main, local.launch_command_sendgrid, local.launch_command_cloudsql, local.launch_command_email_notif, local.launch_command_gcs))}"
  launch_command_fmt         = "${join(" ", local.launch_command_list)}"
}

/*******************************************
  Activate services
 *******************************************/
resource "google_project_service" "activate_services" {
  count   = "${length(local.services_list)}"
  project = "${local.project_id}"

  service = "${element(local.services_list, count.index)}"
}

/*******************************************
  Generate Service Accounts
 *******************************************/
resource "google_service_account" "forseti_server_sa" {
  project      = "${local.project_id}"
  account_id   = "forseti-server-gcp-${random_string.rand.result}"
  display_name = "forseti-server-gcp-${random_string.rand.result}"
}

resource "google_service_account" "forseti_client_sa" {
  project      = "${local.project_id}"
  account_id   = "forseti-client-gcp-${random_string.rand.result}"
  display_name = "forseti-server-gcp-${random_string.rand.result}"
}

/*******************************************
  Provision Service Accounts
 *******************************************/

resource "google_organization_iam_member" "server_org_roles" {
  count      = "${length(local.server_org_roles)}"
  org_id     = "${local.org_id}"
  role       = "${element(local.server_org_roles, count.index)}"
  member     = "serviceAccount:${google_service_account.forseti_server_sa.email}"
  depends_on = ["google_service_account.forseti_server_sa"]
}

resource "google_project_iam_member" "server_project_roles" {
  count      = "${length(local.server_project_roles)}"
  project    = "${local.project_id}"
  role       = "${element(local.server_project_roles, count.index)}"
  member     = "serviceAccount:${google_service_account.forseti_server_sa.email}"
  depends_on = ["google_service_account.forseti_server_sa"]
}

resource "google_project_iam_member" "client_roles" {
  count      = "${length(local.client_roles)}"
  project    = "${local.project_id}"
  role       = "${element(local.client_roles, count.index)}"
  member     = "serviceAccount:${google_service_account.forseti_client_sa.email}"
  depends_on = ["google_service_account.forseti_client_sa"]
}

/*******************************************
  Create Firewall Rules
 *******************************************/
resource "google_compute_firewall" "forseti-server-deny-all" {
  name                    = "forseti-server-deny-all-${random_string.rand.result}"
  network                 = "${google_compute_network.default.name}"
  target_service_accounts = "${google_service_account.forseti_server_sa.email}"
  source_ranges           = ["0.0.0.0/0"]
  priority                = "1"

  deny {
    protocol = "icmp"
  }

  deny {
    protocol = "udp"
  }

  deny {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "forseti-server-ssh-external" {
  name                    = "forseti-server-ssh-external-${random_string.rand.result}"
  network                 = "${google_compute_network.default.name}"
  target_service_accounts = "${google_service_account.forseti_server_sa.email}"
  source_ranges           = ["0.0.0.0/0"]
  priority                = "0"

  allow {
    protocol = "tcp"
    port     = ["22"]
  }
}

resource "google_compute_firewall" "forseti-server-allow-grpc" {
  name                    = "forseti-server-allow-grpc-${random_string.rand.result}"
  network                 = "${google_compute_network.default.name}"
  target_service_accounts = "${google_service_account.forseti_server_sa.email}"
  source_ranges           = ["10.128.0.0/9"]
  priority                = "0"

  allow {
    protocol = "tcp"
    port     = ["50051"]
  }
}

/*******************************************
   Repo downloading
 *******************************************/
resource "null_resource" "get_repo" {
  count = "${local.should_download ? 1 : 0}"

  # Remove foresti existing repo
  provisioner "local-exec" {
    command = "rm -rf forseti-security"
  }

  # Clone repository
  provisioner "local-exec" {
    command = "git clone --single-branch -b ${var.forseti_repo_branch} ${var.forseti_repo_url}"
  }
}

/*******************************************
   Forseti execution
 *******************************************/
resource "null_resource" "deploy_forseti_server" {
  # Execute forseti installation
  provisioner "local-exec" {
    command = "cd forseti-security; gcloud deployment-manager deployments create forseti-server-${random_string.rand.result} --composite-type deployment-templates/deploy-forseti-server.yaml.in --properties {BUCKET_LOCATION:${var.gcs_location}}"

    environment {
      CLOUDSDK_CORE_PROJECT = "${local.project_id}"
    }
  }

  depends_on = ["null_resource.get_repo", "google_project_service.activate_services"]
}

/*******************************************
   Buckets list retrieval
 *******************************************/
data "external" "bucket_retrieval" {
  program = ["bash", "${path.module}/scripts/get-project-buckets.sh", "${var.credentials_file_path}"]

  #depends_on = ["null_resource.execute_forseti"]
}
