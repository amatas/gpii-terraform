terraform {
  backend "gcs" {}
}

provider "google-beta" {
  project     = "${var.project_id}"
  credentials = "${var.serviceaccount_key}"
}

variable "nonce" {}
variable "domain_name" {}
variable "env" {}
variable "organization_id" {}
variable "project_id" {}
variable "serviceaccount_key" {}
variable "auth_user_email" {}

# Terragrunt variables

variable "notification_email" {}

variable "use_auth_user_email" {
  default = false
}

# Enables debug mode when TF_VAR_stackdriver_debug is not empty

variable "stackdriver_debug" {
  default = ""
}

resource "template_dir" "resources" {
  source_dir      = "${path.cwd}/resources"
  destination_dir = "${path.cwd}/resources_rendered"

  vars {
    project_id         = "${var.project_id}"
    organization_id    = "${var.organization_id}"
    domain_name        = "${var.domain_name}"
    notification_email = "${(var.use_auth_user_email && var.auth_user_email != "") ? var.auth_user_email : var.notification_email}"

    enabled = "${(var.env == "prd" || var.env == "stg") ? true : false}"
  }
}

resource "null_resource" "destroy_stackdriver_monitoring" {
  depends_on = ["template_dir.resources"]

  triggers = {
    nonce = "${var.nonce}"
  }

  provisioner "local-exec" {
    command = <<EOF
      export PROJECT_ID=${var.project_id}
      export GOOGLE_CLOUD_KEYFILE=${var.serviceaccount_key}

      RETRIES=5
      RETRY_COUNT=1
      while [ "$STACKDRIVER_DEADLINE_EXCEEDED" != "false" ]; do
        STACKDRIVER_DEADLINE_EXCEEDED="false"
        echo "[Try $RETRY_COUNT of $RETRIES] Destroying Stackdriver resources..."
        bundle exec ruby -e '
          require "/rakefiles/stackdriver.rb"
          destroy_resources({"alert_policies"=>[],"notification_channels"=>[]})
          destroy_uptime_checks(["${join("\",\"", google_monitoring_uptime_check_config.this.*.name)}"])
        '
        STACKDRIVER_EXIT_STATUS="$?"
        if [ "$STACKDRIVER_EXIT_STATUS" == "120" ]; then
          STACKDRIVER_DEADLINE_EXCEEDED="true"
        elif [ "$STACKDRIVER_EXIT_STATUS" != "0" ]; then
          exit $STACKDRIVER_EXIT_STATUS
        fi
        if [ "$RETRY_COUNT" == "$RETRIES" ] && [ "$STACKDRIVER_DEADLINE_EXCEEDED" == "true" ]; then
          echo "Retry limit reached, giving up!"
          exit 1
        fi
        if [ "$STACKDRIVER_DEADLINE_EXCEEDED" == "true" ]; then
          sleep 10
        fi
        RETRY_COUNT=$(($RETRY_COUNT+1))
      done

      RETRIES=5
      RETRY_COUNT=1
      unset STACKDRIVER_DEADLINE_EXCEEDED
      while [ "$STACKDRIVER_DEADLINE_EXCEEDED" != "false" ]; do
        STACKDRIVER_DEADLINE_EXCEEDED="false"
        echo "[Try $RETRY_COUNT of $RETRIES] Destroying Stackdriver resources..."
        bundle exec ruby -e '
          require "/rakefiles/stackdriver.rb"
          destroy_resources({"log_based_metrics"=>[]})
        '
        STACKDRIVER_EXIT_STATUS="$?"
        if [ "$STACKDRIVER_EXIT_STATUS" == "120" ]; then
          STACKDRIVER_DEADLINE_EXCEEDED="true"
        elif [ "$STACKDRIVER_EXIT_STATUS" != "0" ]; then
          exit $STACKDRIVER_EXIT_STATUS
        fi
        if [ "$RETRY_COUNT" == "$RETRIES" ] && [ "$STACKDRIVER_DEADLINE_EXCEEDED" == "true" ]; then
          echo "Retry limit reached, giving up!"
          exit 1
        fi
        if [ "$STACKDRIVER_DEADLINE_EXCEEDED" == "true" ]; then
          sleep 10
        fi
        RETRY_COUNT=$(($RETRY_COUNT+1))
      done
    EOF
  }
}
