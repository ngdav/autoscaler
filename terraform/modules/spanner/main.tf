/**
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

## - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
## If Terraform must create a test instance to be Autoscaled
##
resource "google_spanner_instance" "main" {
  count = var.terraform_spanner_test ? 1 : 0

  name         = var.spanner_name
  config       = "regional-${var.region}"
  display_name = var.spanner_name
  project      = var.project_id

  processing_units = 100

  lifecycle {
    ignore_changes = [num_nodes, processing_units]
  }
}

resource "google_spanner_database" "test-database" {
  count = var.terraform_spanner_test ? 1 : 0

  instance = var.spanner_name
  name     = "my-database"
  ddl = [
    "CREATE TABLE t1 (t1 INT64 NOT NULL,) PRIMARY KEY(t1)",
    "CREATE TABLE t2 (t2 INT64 NOT NULL,) PRIMARY KEY(t2)",
  ]
  # Must specify project because provider project may be different than var.project_id
  project = var.project_id

  depends_on          = [google_spanner_instance.main]
  deletion_protection = false
}

## - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
## Give permissions to the poller and scaler service accounts
## on the monitored Spanner instance
##

# Allows poller to get Spanner metrics
resource "google_project_iam_member" "poller_get_metrics_iam" {
  role    = "roles/monitoring.viewer"
  project = var.project_id
  member  = "serviceAccount:${var.poller_sa_email}"
}

resource "google_spanner_instance_iam_member" "poller_get_metadata_iam" {
  instance = var.spanner_name
  role     = "roles/spanner.viewer"
  project  = var.project_id
  member   = "serviceAccount:${var.poller_sa_email}"

  depends_on = [google_spanner_instance.main]
}

# Limited role
resource "google_project_iam_custom_role" "capacity_manager_iam_role" {
  role_id     = "spannerAutoscalerCapacityManager"
  title       = "Spanner Autoscaler Capacity Manager Role"
  description = "Allows a principal to scale spanner instances"
  permissions = ["spanner.instanceOperations.get", "spanner.instances.update"]
}

# Allows scaler to modify the capacity (nodes or PUs) of the Spanner instance
resource "google_spanner_instance_iam_member" "scaler_update_capacity_iam" {
  instance = var.spanner_name
  role     = google_project_iam_custom_role.capacity_manager_iam_role.name
  project  = var.project_id
  member   = "serviceAccount:${var.scaler_sa_email}"

  depends_on = [google_spanner_instance.main]
}

## - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -  
## If Terraform must create an instance to store the state of the Autoscaler
##
resource "google_spanner_instance" "state_instance" {
  count = var.terraform_spanner_state ? 1 : 0

  name         = var.state_spanner_name
  config       = "regional-${var.region}"
  display_name = var.state_spanner_name
  project      = var.project_id

  processing_units = 100
}

resource "google_spanner_database" "state-database" {
  count = var.terraform_spanner_state ? 1 : 0

  instance = var.state_spanner_name
  name     = "spanner-autoscaler-state"
  ddl = [
    <<EOT
    CREATE TABLE spannerAutoscaler (
      id STRING(MAX),
      lastScalingTimestamp TIMESTAMP,
      createdOn TIMESTAMP,
      updatedOn TIMESTAMP,
    ) PRIMARY KEY (id)
    EOT
  ]
  # Must specify project because provider project may be different than var.project_id
  project = var.project_id

  depends_on          = [google_spanner_instance.state_instance]
  deletion_protection = false
}

# Allows scaler to read/write the state from/in Spanner
resource "google_spanner_instance_iam_member" "spanner_state_user" {
  count = var.terraform_spanner_state ? 1 : 0

  instance = var.state_spanner_name
  role     = "roles/spanner.databaseUser"
  project  = var.project_id
  member   = "serviceAccount:${var.scaler_sa_email}"

  depends_on = [google_spanner_instance.state_instance]
}
